// Package onboard performs the writes that admit a regional appliance to a
// stage, and issues the one proof that travels back to it.
//
// Five things have to be true before an appliance works, and none of them is
// configuration, so no apply creates them:
//
//   - its Piri DID is on the delegator's allow list, or `piri init` is refused
//     with a 403 at the approval step
//   - sprue knows its Piri as a provider with an endpoint and a weight, or
//     uploads fail with CandidateUnavailable
//   - hilt knows its Ingot as the provider for its region, or hilt rejects every
//     tenant in that region
//   - its Piri is a storage node of that provider, or the region's routing
//     policy never sends a bucket's data to it
//   - its Ingot holds hilt's S3 delegation, which only central can sign
//
// Central also records the appliance's Piri DID under its region. That record
// is the region's node set: hilt keeps only the routing policy's DID and sprue
// holds the candidates, and neither offers a read of them, so a Piri joining a
// registered region is sent to hilt together with every Piri recorded before it.
// A provider registered before hilt took storage nodes has no policy, and hilt
// says so, so the same write repairs it from the record.
//
// Every step reads before it writes, and reports what it found before anything
// is changed. That is not only for the operator's benefit: hilt raises the same
// "already registered" error whether the DID is registered for this region or a
// different one, so trusting the error alone silently accepts a mismatch that
// breaks every request afterwards. smelt learned that the hard way and verifies
// what hilt holds; so does this.
package onboard

import (
	"context"
	"fmt"
	"slices"
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

// HiltAdmin is the slice of hilt's admin API this package uses. Provider reads
// back what hilt holds for a DID, through hilt's own list command, so a write is
// verified rather than trusted.
type HiltAdmin interface {
	Provider(ctx context.Context, did string) (*HiltProvider, error)
	AddProvider(ctx context.Context, did, region string, nodes []string) error
	// SetProviderNodes replaces the storage nodes a registered provider serves
	// with, so it takes the whole set rather than an addition.
	SetProviderNodes(ctx context.Context, did string, nodes []string) error
}

// Provider is sprue's record of a storage provider.
type Provider struct {
	Endpoint          string `json:"endpoint"`
	Weight            int64  `json:"weight"`
	ReplicationWeight int64  `json:"replication_weight"`
}

// HiltProvider is hilt's record of a regional provider.
type HiltProvider struct {
	Region string
	// Policy is the DID of the routing policy whose candidates are the
	// provider's storage nodes, empty when hilt has never been given any.
	Policy string
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

// Deps are the services and record the phase talks to.
type Deps struct {
	AllowList AllowList
	Sprue     SprueAdmin
	Hilt      HiltAdmin
	// IssueProof signs hilt's delegation to this appliance's Ingot and stores it,
	// returning the stored copy. Written once and read back afterwards, because
	// a delegation carries a random nonce and re-issuing one produces different
	// bytes and a different CID.
	IssueProof func(ctx context.Context, region, ingotDID string) (string, error)
	// PiriRecord reads and writes the set of Piri DIDs a region has onboarded.
	PiriRecord PiriRecord
}

// PiriRecord is central's temporary record of which Piri belong to which
// region.
type PiriRecord interface {
	Recorded(ctx context.Context, region string) ([]string, error)
	Record(ctx context.Context, region, piriDID string) error
}

// State is what the three services hold for this appliance right now.
type State struct {
	Region      string    `json:"region"`
	AllowListed bool      `json:"allow_listed"`
	Sprue       *Provider `json:"sprue,omitempty"`
	// HiltRegion is the region hilt has this Ingot registered for, empty when it
	// has no record at all.
	HiltRegion string `json:"hilt_region"`
	// HiltPolicy is the routing policy carrying the Ingot's storage nodes, empty
	// when hilt holds none for it.
	HiltPolicy string `json:"hilt_policy"`
	// RecordedPiris are the Piri DIDs central has recorded for the region, which
	// is also the storage node set hilt was last given for it.
	RecordedPiris []string `json:"recorded_piris"`
	PiriRecorded  bool     `json:"piri_recorded"`
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

	hilt, err := deps.Hilt.Provider(ctx, req.IngotDID)
	if err != nil {
		return nil, fmt.Errorf("read hilt's provider record: %w", err)
	}
	if hilt != nil {
		state.HiltRegion = hilt.Region
		state.HiltPolicy = hilt.Policy
	}

	recorded, err := deps.PiriRecord.Recorded(ctx, req.Region)
	if err != nil {
		return nil, fmt.Errorf("read the region's recorded Piri DIDs: %w", err)
	}
	state.RecordedPiris = recorded
	state.PiriRecorded = slices.Contains(recorded, req.PiriDID)

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
			"hilt has %s registered for region %s, not %s; hilt has no command to move a provider, so retire the region it names with make retire-region before onboarding again",
			req.IngotDID, state.HiltRegion, req.Region))
	case state.HiltPolicy == "":
		// Registered before hilt took storage nodes, so the region's buckets
		// still use sprue's default routing.
		plan.Actions = append(plan.Actions, fmt.Sprintf(
			"set %s's storage nodes in hilt to %s", req.IngotDID,
			strings.Join(nodeSet(state, req), ", ")))
	case !state.PiriRecorded:
		plan.Actions = append(plan.Actions, fmt.Sprintf(
			"add %s to %s's storage nodes in hilt", req.PiriDID, req.IngotDID))
	}

	if !state.PiriRecorded {
		plan.Actions = append(plan.Actions, fmt.Sprintf(
			"record %s as a Piri of region %s", req.PiriDID, req.Region))
	}

	return plan
}

// nodeSet is the storage node set hilt is given for the region: every Piri
// recorded for it plus the one onboarding now.
func nodeSet(state *State, req Request) []string {
	if state.PiriRecorded {
		return state.RecordedPiris
	}
	return append(slices.Clone(state.RecordedPiris), req.PiriDID)
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

	// When writing to hilt, always send the region's whole node set, because hilt
	// holds no list to add to: the set is the candidates of the routing policy it
	// keeps on sprue, and setting them replaces them. The set comes from central's
	// record, which is written after this so that a recorded Piri is always one
	// hilt has been told about.
	nodes := nodeSet(&plan.State, req)

	switch {
	case plan.HiltRegion == "":
		if err := deps.Hilt.AddProvider(ctx, req.IngotDID, req.Region, nodes); err != nil {
			return nil, fmt.Errorf("register %s with hilt: %w", req.IngotDID, err)
		}

		// Verify rather than trust the call. hilt answers "already registered"
		// for a DID held under a different region as well as for this one, so
		// what it now holds is the only thing that actually says what happened.
		hilt, err := deps.Hilt.Provider(ctx, req.IngotDID)
		if err != nil {
			return nil, fmt.Errorf("verify hilt's provider record: %w", err)
		}
		if hilt == nil || hilt.Region != req.Region {
			region := ""
			if hilt != nil {
				region = hilt.Region
			}
			return nil, fmt.Errorf(
				"hilt reported success but holds %s for region %q, want %q; retire that region with make retire-region before retrying",
				req.IngotDID, region, req.Region)
		}
		result.Performed = append(result.Performed, "registered "+req.IngotDID+" with hilt for "+req.Region)
	case plan.HiltPolicy == "" || !plan.PiriRecorded:
		if err := deps.Hilt.SetProviderNodes(ctx, req.IngotDID, nodes); err != nil {
			return nil, fmt.Errorf("set %s's storage nodes in hilt: %w", req.IngotDID, err)
		}
		result.Performed = append(result.Performed,
			"set "+req.IngotDID+"'s storage nodes in hilt to "+strings.Join(nodes, ", "))
	}

	if !plan.PiriRecorded {
		if err := deps.PiriRecord.Record(ctx, req.Region, req.PiriDID); err != nil {
			return nil, fmt.Errorf("record %s as a Piri of region %s: %w", req.PiriDID, req.Region, err)
		}
		result.Performed = append(result.Performed,
			"recorded "+req.PiriDID+" as a Piri of "+req.Region)
	}

	proof, err := deps.IssueProof(ctx, req.Region, req.IngotDID)
	if err != nil {
		return nil, fmt.Errorf("issue hilt's delegation to %s: %w", req.IngotDID, err)
	}
	result.HiltIngotS3Proof = proof

	return result, nil
}
