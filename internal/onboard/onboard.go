// Package onboard performs the writes that admit a regional appliance to a
// stage, and issues the one proof that travels back to it.
//
// Four things have to be true before an appliance works, and none of them is
// configuration, so no apply creates them:
//
//   - its Piri DID is on the delegator's allow list, or `piri init` is refused
//     with a 403 at the approval step
//   - sprue knows its Piri as a provider with an endpoint and a weight, or
//     uploads fail with CandidateUnavailable
//   - hilt knows its Ingot as the provider for its region, or hilt rejects every
//     tenant in that region
//   - its Ingot holds hilt's S3 delegation, which only central can sign
//
// Every step reads before it writes, and reports what it found before anything
// is changed. That is not only for the operator's benefit: hilt raises the same
// "already registered" error whether the DID is registered for this region or a
// different one, so trusting the error alone silently accepts a mismatch that
// breaks every request afterwards. smelt learned that the hard way and verifies
// the row; so does this.
package onboard

import (
	"context"
	"fmt"
	"strings"
)

// AllowList is the delegator's set of DIDs permitted to onboard.
type AllowList interface {
	Has(ctx context.Context, did string) (bool, error)
	Add(ctx context.Context, did string) error
}

// SprueAdmin is the slice of sprue's admin API this package uses.
type SprueAdmin interface {
	Provider(ctx context.Context, did string) (*Provider, error)
	Register(ctx context.Context, did, endpoint string, proof []byte) error
	SetWeight(ctx context.Context, did string, weight, replicationWeight int) error
}

// HiltAdmin is the slice of hilt's admin API this package uses, plus the
// database read that verifies it. hilt has no provider list command, so the row
// is read directly.
type HiltAdmin interface {
	ProviderRegion(ctx context.Context, did string) (string, error)
	AddProvider(ctx context.Context, did, region string) error
}

// Provider is sprue's record of a storage provider.
type Provider struct {
	Endpoint          string `json:"endpoint"`
	Weight            int64  `json:"weight"`
	ReplicationWeight int64  `json:"replication_weight"`
}

// Request is the appliance presenting itself: its Piri DID, where that Piri
// answers, and the delegation it signed for sprue. IngotDID is derived from the
// region by the caller rather than sent by the appliance.
type Request struct {
	Region   string
	PiriDID  string
	IngotDID string
	PiriURL  string
	// PiriProof is the delegation the appliance signed with its own Piri key,
	// authorising sprue to invoke blob and pdp commands on it. Central never
	// holds that key, so this can only come from the appliance.
	PiriProof []byte

	Weight            int
	ReplicationWeight int
}

// Deps are the four things the phase talks to.
type Deps struct {
	AllowList AllowList
	Sprue     SprueAdmin
	Hilt      HiltAdmin
	// IssueProof signs hilt's delegation to this appliance's Ingot and stores it,
	// returning the stored copy. Written once and read back afterwards, because
	// a delegation carries a random nonce and re-issuing one produces different
	// bytes and a different CID.
	IssueProof func(ctx context.Context, region, ingotDID string) (string, error)
}

// State is what the three services hold for this appliance right now.
type State struct {
	Region      string    `json:"region"`
	AllowListed bool      `json:"allow_listed"`
	Sprue       *Provider `json:"sprue,omitempty"`
	// HiltRegion is the region hilt has this Ingot registered for, empty when it
	// has no row at all.
	HiltRegion string `json:"hilt_region"`
}

// Plan is State plus what would be done about it.
type Plan struct {
	State
	// Actions describes each write in the order it will happen. Empty means the
	// appliance is already registered and only the proof is returned.
	Actions []string `json:"actions"`
	// Blockers are conditions no write can resolve. A plan with any of these
	// performs nothing.
	Blockers []string `json:"blockers,omitempty"`
}

// Read reports what the three services hold for this appliance.
func Read(ctx context.Context, deps Deps, req Request) (*State, error) {
	state := &State{Region: req.Region}

	allowed, err := deps.AllowList.Has(ctx, req.PiriDID)
	if err != nil {
		return nil, fmt.Errorf("read the delegator allow list: %w", err)
	}
	state.AllowListed = allowed

	provider, err := deps.Sprue.Provider(ctx, req.PiriDID)
	if err != nil {
		return nil, fmt.Errorf("read sprue's providers: %w", err)
	}
	state.Sprue = provider

	region, err := deps.Hilt.ProviderRegion(ctx, req.IngotDID)
	if err != nil {
		return nil, fmt.Errorf("read hilt's provider row: %w", err)
	}
	state.HiltRegion = region

	return state, nil
}

// PlanFrom decides what to do about the state that was read.
//
// A mismatch is a blocker rather than an action, because every fix for one
// destroys something: hilt has no command to move a provider between regions,
// and re-registering a provider at a new endpoint in sprue changes where uploads
// are sent. Whoever is onboarding needs to see the conflict and choose.
func PlanFrom(state *State, req Request) *Plan {
	plan := &Plan{State: *state}

	if !state.AllowListed {
		plan.Actions = append(plan.Actions,
			fmt.Sprintf("add %s to the delegator's allow list", req.PiriDID))
	}

	switch {
	case state.Sprue == nil && len(req.PiriProof) == 0:
		// Central cannot produce this proof, so no run can get past sprue
		// registration without it. It is a blocker rather than an error raised
		// during the writes, so a dry run says so and a confirmed run leaves
		// the appliance half-admitted.
		plan.Blockers = append(plan.Blockers, fmt.Sprintf(
			"registering %s with sprue needs the proof the appliance signed with its Piri key, and the request carries none",
			req.PiriDID))
	case state.Sprue == nil:
		plan.Actions = append(plan.Actions,
			fmt.Sprintf("register %s with sprue at %s", req.PiriDID, req.PiriURL))
	case state.Sprue.Endpoint != req.PiriURL:
		plan.Blockers = append(plan.Blockers, fmt.Sprintf(
			"sprue has %s registered at %s, not %s; re-registering moves where uploads are sent, so deregister it deliberately first",
			req.PiriDID, state.Sprue.Endpoint, req.PiriURL))
	}

	if state.Sprue == nil ||
		state.Sprue.Weight != int64(req.Weight) ||
		state.Sprue.ReplicationWeight != int64(req.ReplicationWeight) {
		plan.Actions = append(plan.Actions, fmt.Sprintf(
			"set %s's weights to %d and %d", req.PiriDID, req.Weight, req.ReplicationWeight))
	}

	switch {
	case state.HiltRegion == "":
		plan.Actions = append(plan.Actions,
			fmt.Sprintf("register %s with hilt for region %s", req.IngotDID, req.Region))
	case state.HiltRegion != req.Region:
		// This is the failure smelt's tolerance of "already registered" once
		// masked. hilt has no way to move a provider, so it cannot be an action.
		plan.Blockers = append(plan.Blockers, fmt.Sprintf(
			"hilt has %s registered for region %s, not %s; hilt has no command to move a provider, so the row has to be corrected in its database by hand",
			req.IngotDID, state.HiltRegion, req.Region))
	}

	return plan
}

// Result reports what Apply did and carries the proof back to the appliance.
type Result struct {
	Region string `json:"region"`
	// Performed lists what this run actually wrote. It is not the plan's action
	// list: the weights are set on every run, so they appear here even when the
	// plan saw nothing to change about them.
	Performed []string `json:"performed"`
	// HiltIngotS3Proof is the delegation the appliance's Ingot needs. Public: a
	// delegation is useless without the audience's own key.
	HiltIngotS3Proof string `json:"hilt_ingot_s3_proof"`
}

// Apply performs the plan's writes and returns the appliance's proof.
//
// Every write is verified rather than assumed, because the admin APIs report
// success and near-success the same way.
func Apply(ctx context.Context, deps Deps, req Request, plan *Plan) (*Result, error) {
	if len(plan.Blockers) > 0 {
		return nil, fmt.Errorf("refusing to write: %s", strings.Join(plan.Blockers, "; and "))
	}

	result := &Result{Region: req.Region}

	if !plan.AllowListed {
		if err := deps.AllowList.Add(ctx, req.PiriDID); err != nil {
			return nil, fmt.Errorf("allow-list %s: %w", req.PiriDID, err)
		}
		result.Performed = append(result.Performed, "allow-listed "+req.PiriDID)
	}

	if plan.Sprue == nil {
		if err := deps.Sprue.Register(ctx, req.PiriDID, req.PiriURL, req.PiriProof); err != nil {
			return nil, fmt.Errorf("register %s with sprue: %w", req.PiriDID, err)
		}
		result.Performed = append(result.Performed, "registered "+req.PiriDID+" with sprue")
	}

	// The weights are set on every run that reaches here. They are two integers
	// derived from the request, so writing them again cannot change anything a
	// previous run established, and it repairs a provider registered with the
	// defaults sprue assigns.
	if err := deps.Sprue.SetWeight(ctx, req.PiriDID, req.Weight, req.ReplicationWeight); err != nil {
		return nil, fmt.Errorf("set %s's weights: %w", req.PiriDID, err)
	}
	result.Performed = append(result.Performed, "set sprue weights")

	if plan.HiltRegion == "" {
		if err := deps.Hilt.AddProvider(ctx, req.IngotDID, req.Region); err != nil {
			return nil, fmt.Errorf("register %s with hilt: %w", req.IngotDID, err)
		}

		// Verify rather than trust the call. hilt answers "already registered"
		// for a DID held under a different region as well as for this one, so
		// the row is the only thing that actually says what happened.
		region, err := deps.Hilt.ProviderRegion(ctx, req.IngotDID)
		if err != nil {
			return nil, fmt.Errorf("verify hilt's provider row: %w", err)
		}
		if region != req.Region {
			return nil, fmt.Errorf(
				"hilt reported success but its row for %s says region %q, want %q; correct the row in hilt's database before retrying",
				req.IngotDID, region, req.Region)
		}
		result.Performed = append(result.Performed, "registered "+req.IngotDID+" with hilt for "+req.Region)
	}

	proof, err := deps.IssueProof(ctx, req.Region, req.IngotDID)
	if err != nil {
		return nil, fmt.Errorf("issue hilt's delegation to %s: %w", req.IngotDID, err)
	}
	result.HiltIngotS3Proof = proof

	return result, nil
}
