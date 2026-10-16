package onboard

import (
	"context"
	"fmt"
	"slices"
	"strings"
)

// Removing a Piri undoes what onboarding wrote for it, and the row the delegator
// wrote for it at `piri init`, so that nothing central or the delegator holds
// still names the DID:
//
//   - hilt's storage node set for the region, given again without the Piri
//   - sprue's provider row, which carries its endpoint and weights
//   - the delegator's allow-list entry
//   - the delegator's provider-info row, written by the delegator itself
//   - central's record of the Piri under its region
//
// The writes run in the reverse of onboarding's order, and the record goes last:
// it is how a run finds the Piri's region and the rest of the region's node set,
// so a run that fails halfway leaves enough behind for the next one to finish.
//
// The Piri's on-chain provider and its data sets belong to its own wallet, which
// central never holds, so they are left as they are.

// AllowListRemover is the slice of the delegator's allow list removal uses.
type AllowListRemover interface {
	Has(ctx context.Context, did string) (bool, error)
	Remove(ctx context.Context, did string) error
}

// SprueDeregisterer is the slice of sprue's admin API removal uses.
type SprueDeregisterer interface {
	Provider(ctx context.Context, did string) (*Provider, error)
	Deregister(ctx context.Context, did string) error
}

// ProviderInfo is the delegator's record of each Piri that completed `piri
// init`, keyed by its DID.
type ProviderInfo interface {
	Has(ctx context.Context, did string) (bool, error)
	Remove(ctx context.Context, did string) error
}

// PiriRecordRemover reads and removes central's record of a region's Piri.
type PiriRecordRemover interface {
	Recorded(ctx context.Context, region string) ([]string, error)
	// Regions lists every region of the stage the DID is recorded under.
	Regions(ctx context.Context, piriDID string) ([]string, error)
	Remove(ctx context.Context, region, piriDID string) error
}

// RemoveDeps are the services and record removal talks to.
type RemoveDeps struct {
	AllowList    AllowListRemover
	Sprue        SprueDeregisterer
	Hilt         HiltAdmin
	ProviderInfo ProviderInfo
	PiriRecord   PiriRecordRemover
}

// RemoveRequest names the Piri to remove and the region it belongs to.
// IngotDID is derived from the region by the caller.
type RemoveRequest struct {
	Region   string
	PiriDID  string
	IngotDID string
}

// RemoveState is what each service holds for the Piri right now.
type RemoveState struct {
	Region       string    `json:"region"`
	PiriDID      string    `json:"piri_did"`
	AllowListed  bool      `json:"allow_listed"`
	ProviderInfo bool      `json:"provider_info"`
	Sprue        *Provider `json:"sprue,omitempty"`
	HiltRegion   string    `json:"hilt_region"`
	HiltPolicy   string    `json:"hilt_policy"`
	// RecordedPiris are the Piri DIDs central has recorded for the region,
	// which is also the storage node set hilt was last given for it.
	RecordedPiris []string `json:"recorded_piris"`
	PiriRecorded  bool     `json:"piri_recorded"`
	// RecordedRegions are every region of the stage the DID is recorded under.
	RecordedRegions []string `json:"recorded_regions"`
}

// RemovePlan is RemoveState plus what would be done about it.
type RemovePlan struct {
	RemoveState
	// Actions describes each write in the order it will happen. Empty means
	// nothing holds the Piri any more.
	Actions []string `json:"actions"`
	// Blockers are conditions no write can resolve. A plan with any of these
	// performs nothing.
	Blockers []string `json:"blockers,omitempty"`
	// Notes are what the operator should know and no write changes.
	Notes []string `json:"notes"`
}

// RemoveResult reports what ApplyRemoval did.
type RemoveResult struct {
	Region    string   `json:"region"`
	PiriDID   string   `json:"piri_did"`
	Performed []string `json:"performed"`
}

// ReadRemoval reports what each service holds for the Piri.
func ReadRemoval(ctx context.Context, deps RemoveDeps, req RemoveRequest) (*RemoveState, error) {
	state := &RemoveState{Region: req.Region, PiriDID: req.PiriDID}

	regions, err := deps.PiriRecord.Regions(ctx, req.PiriDID)
	if err != nil {
		return nil, fmt.Errorf("find the regions %s is recorded under: %w", req.PiriDID, err)
	}
	state.RecordedRegions = regions

	recorded, err := deps.PiriRecord.Recorded(ctx, req.Region)
	if err != nil {
		return nil, fmt.Errorf("read the region's recorded Piri DIDs: %w", err)
	}
	state.RecordedPiris = recorded
	state.PiriRecorded = slices.Contains(recorded, req.PiriDID)

	hilt, err := deps.Hilt.Provider(ctx, req.IngotDID)
	if err != nil {
		return nil, fmt.Errorf("read hilt's provider record: %w", err)
	}
	if hilt != nil {
		state.HiltRegion = hilt.Region
		state.HiltPolicy = hilt.Policy
	}

	provider, err := deps.Sprue.Provider(ctx, req.PiriDID)
	if err != nil {
		return nil, fmt.Errorf("read sprue's providers: %w", err)
	}
	state.Sprue = provider

	allowed, err := deps.AllowList.Has(ctx, req.PiriDID)
	if err != nil {
		return nil, fmt.Errorf("read the delegator allow list: %w", err)
	}
	state.AllowListed = allowed

	info, err := deps.ProviderInfo.Has(ctx, req.PiriDID)
	if err != nil {
		return nil, fmt.Errorf("read the delegator's provider info: %w", err)
	}
	state.ProviderInfo = info

	return state, nil
}

// PlanRemoval decides what to do about the state that was read.
func PlanRemoval(state *RemoveState, req RemoveRequest) *RemovePlan {
	plan := &RemovePlan{
		RemoveState: *state,
		Notes: []string{
			"the Piri's on-chain provider registration and data sets belong to its own wallet and are left as they are",
		},
	}

	// Removing under the wrong region would give hilt that region's node set
	// minus a Piri it never had, and leave the real region's record and node set
	// naming a provider sprue no longer knows.
	if others := otherRegions(state.RecordedRegions, req.Region); len(others) > 0 {
		plan.Blockers = append(plan.Blockers, fmt.Sprintf(
			"%s is recorded as a Piri of region %s, not %s; run remove-piri with that region",
			req.PiriDID, strings.Join(others, ", "), req.Region))
	}

	if state.PiriRecorded {
		remaining := remainingNodes(state, req)
		switch {
		case state.HiltRegion != "" && state.HiltRegion != req.Region:
			plan.Blockers = append(plan.Blockers, fmt.Sprintf(
				"hilt has %s registered for region %s, not %s, so its storage nodes are not this region's to change",
				req.IngotDID, state.HiltRegion, req.Region))
		case state.HiltPolicy == "":
			// No node set to take the Piri out of: hilt has no row for the
			// region, as after make retire-region, or a row from before it took
			// storage nodes.
		case len(remaining) == 0:
			// hilt refuses an empty node set and sprue refuses an empty routing
			// policy, so the only Piri hilt routes the region to cannot leave.
			plan.Blockers = append(plan.Blockers, fmt.Sprintf(
				"%s is the only storage node hilt routes region %s to, and hilt refuses an empty set; onboard another Piri first, or, when the whole node is leaving, delete hilt's row with make retire-region and run this again",
				req.PiriDID, req.Region))
		default:
			plan.Actions = append(plan.Actions, fmt.Sprintf(
				"set %s's storage nodes in hilt to %s", req.IngotDID, strings.Join(remaining, ", ")))
		}
	}

	if state.Sprue != nil {
		plan.Actions = append(plan.Actions, fmt.Sprintf(
			"deregister %s from sprue, where it is registered at %s", req.PiriDID, state.Sprue.Endpoint))
	}

	if state.AllowListed {
		plan.Actions = append(plan.Actions,
			fmt.Sprintf("remove %s from the delegator's allow list", req.PiriDID))
	}

	if state.ProviderInfo {
		plan.Actions = append(plan.Actions,
			fmt.Sprintf("remove %s from the delegator's provider info", req.PiriDID))
	}

	if state.PiriRecorded {
		plan.Actions = append(plan.Actions,
			fmt.Sprintf("remove %s from region %s's recorded Piris", req.PiriDID, req.Region))
	}

	return plan
}

// ApplyRemoval performs the plan's writes, in the plan's order.
func ApplyRemoval(ctx context.Context, deps RemoveDeps, req RemoveRequest, plan *RemovePlan) (*RemoveResult, error) {
	if len(plan.Blockers) > 0 {
		return nil, fmt.Errorf("refusing to write: %s", strings.Join(plan.Blockers, "; and "))
	}

	result := &RemoveResult{Region: req.Region, PiriDID: req.PiriDID, Performed: []string{}}

	// hilt first: sprue accepts a routing policy only while every candidate is a
	// registered provider, so the Piri leaves the node set before sprue forgets it.
	if plan.PiriRecorded && plan.HiltPolicy != "" {
		nodes := remainingNodes(&plan.RemoveState, req)
		if err := deps.Hilt.SetProviderNodes(ctx, req.IngotDID, nodes); err != nil {
			return nil, fmt.Errorf("set %s's storage nodes in hilt: %w", req.IngotDID, err)
		}
		result.Performed = append(result.Performed,
			"set "+req.IngotDID+"'s storage nodes in hilt to "+strings.Join(nodes, ", "))
	}

	if plan.Sprue != nil {
		if err := deps.Sprue.Deregister(ctx, req.PiriDID); err != nil {
			return nil, fmt.Errorf("deregister %s from sprue: %w", req.PiriDID, err)
		}
		result.Performed = append(result.Performed, "deregistered "+req.PiriDID+" from sprue")
	}

	if plan.AllowListed {
		if err := deps.AllowList.Remove(ctx, req.PiriDID); err != nil {
			return nil, fmt.Errorf("remove %s from the allow list: %w", req.PiriDID, err)
		}
		result.Performed = append(result.Performed, "removed "+req.PiriDID+" from the allow list")
	}

	if plan.ProviderInfo {
		if err := deps.ProviderInfo.Remove(ctx, req.PiriDID); err != nil {
			return nil, fmt.Errorf("remove %s from the provider info: %w", req.PiriDID, err)
		}
		result.Performed = append(result.Performed, "removed "+req.PiriDID+" from the provider info")
	}

	if plan.PiriRecorded {
		if err := deps.PiriRecord.Remove(ctx, req.Region, req.PiriDID); err != nil {
			return nil, fmt.Errorf("remove %s from region %s's record: %w", req.PiriDID, req.Region, err)
		}
		result.Performed = append(result.Performed,
			"removed "+req.PiriDID+" from region "+req.Region+"'s record")
	}

	return result, nil
}

// remainingNodes is the region's storage node set once the Piri has left it.
func remainingNodes(state *RemoveState, req RemoveRequest) []string {
	remaining := []string{}
	for _, did := range state.RecordedPiris {
		if did != req.PiriDID {
			remaining = append(remaining, did)
		}
	}
	return remaining
}

func otherRegions(regions []string, region string) []string {
	var others []string
	for _, r := range regions {
		if r != region {
			others = append(others, r)
		}
	}
	return others
}
