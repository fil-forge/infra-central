package onboard

import (
	"context"
	"reflect"
	"strings"
	"testing"
)

func testRemoveRequest() RemoveRequest {
	return RemoveRequest{
		Region:   "us-east-9",
		PiriDID:  "did:key:zPiri",
		IngotDID: "did:key:zIngot",
	}
}

// registeredState is a Piri every registry holds, in a region with a second Piri.
func registeredState() *RemoveState {
	return &RemoveState{
		Region:          "us-east-9",
		PiriDID:         "did:key:zPiri",
		AllowListed:     true,
		ProviderInfo:    true,
		Sprue:           &Provider{Endpoint: "https://piri-0.latest.dev.fil-forge.com", Weight: 100, ReplicationWeight: 100},
		HiltRegion:      "us-east-9",
		HiltPolicy:      "did:key:zPolicy",
		RecordedPiris:   []string{"did:key:zOther", "did:key:zPiri"},
		PiriRecorded:    true,
		RecordedRegions: []string{"us-east-9"},
	}
}

func TestReadRemovalReportsWhatEachRegistryHolds(t *testing.T) {
	fakes := newRemoveFakes()
	fakes.allowList.has = true
	fakes.providerInfo.has = true
	fakes.sprue.provider = &Provider{Endpoint: "https://piri-0.latest.dev.fil-forge.com", Weight: 100, ReplicationWeight: 100}
	fakes.hilt.region = "us-east-9"
	fakes.hilt.policy = "did:key:zPolicy"
	fakes.record.recorded = []string{"did:key:zOther", "did:key:zPiri"}
	fakes.record.regions = []string{"us-east-9"}

	state, err := ReadRemoval(context.Background(), fakes.deps(), testRemoveRequest())
	if err != nil {
		t.Fatal(err)
	}
	if want := registeredState(); !reflect.DeepEqual(state, want) {
		t.Errorf("ReadRemoval() = %+v, want %+v", state, want)
	}
}

func TestPlanRemovalListsEveryWriteInApplyOrder(t *testing.T) {
	plan := PlanRemoval(registeredState(), testRemoveRequest())

	want := []string{
		"set did:key:zIngot's storage nodes in hilt to did:key:zOther",
		"deregister did:key:zPiri from sprue, where it is registered at https://piri-0.latest.dev.fil-forge.com",
		"remove did:key:zPiri from the delegator's allow list",
		"remove did:key:zPiri from the delegator's provider info",
		"remove did:key:zPiri from region us-east-9's recorded Piris",
	}
	if !reflect.DeepEqual(plan.Actions, want) {
		t.Errorf("actions = %v, want %v", plan.Actions, want)
	}
}

func TestPlanRemovalPlansNothingForAPiriNoRegistryHolds(t *testing.T) {
	plan := PlanRemoval(&RemoveState{Region: "us-east-9", PiriDID: "did:key:zPiri"}, testRemoveRequest())

	got := struct {
		Actions  []string
		Blockers []string
	}{plan.Actions, plan.Blockers}
	if got.Actions != nil || got.Blockers != nil {
		t.Errorf("actions and blockers = %+v, want neither", got)
	}
}

// Once make retire-region has deleted hilt's row, the region's last Piri has
// no node set left to leave, so it can be removed like any other.
func TestPlanRemovalRemovesTheLastPiriHiltNoLongerRoutesTo(t *testing.T) {
	state := registeredState()
	state.RecordedPiris = []string{"did:key:zPiri"}
	state.HiltRegion = ""
	state.HiltPolicy = ""

	plan := PlanRemoval(state, testRemoveRequest())

	want := []string{
		"deregister did:key:zPiri from sprue, where it is registered at https://piri-0.latest.dev.fil-forge.com",
		"remove did:key:zPiri from the delegator's allow list",
		"remove did:key:zPiri from the delegator's provider info",
		"remove did:key:zPiri from region us-east-9's recorded Piris",
	}
	got := struct {
		Actions  []string
		Blockers []string
	}{plan.Actions, plan.Blockers}
	if !reflect.DeepEqual(got.Actions, want) || got.Blockers != nil {
		t.Errorf("plan = %+v, want actions %v and no blockers", got, want)
	}
}

func TestPlanRemovalBlocks(t *testing.T) {
	cases := map[string]struct {
		state func() *RemoveState
		want  string
	}{
		"a Piri recorded under another region": {
			state: func() *RemoveState {
				state := registeredState()
				state.RecordedRegions = []string{"eu-central-3"}
				state.RecordedPiris = []string{"did:key:zOther"}
				state.PiriRecorded = false
				return state
			},
			want: "recorded as a Piri of region eu-central-3, not us-east-9",
		},
		"the region's last Piri": {
			state: func() *RemoveState {
				state := registeredState()
				state.RecordedPiris = []string{"did:key:zPiri"}
				return state
			},
			want: "the only storage node hilt routes region us-east-9 to",
		},
		"an Ingot hilt holds for another region": {
			state: func() *RemoveState {
				state := registeredState()
				state.HiltRegion = "eu-central-3"
				return state
			},
			want: "hilt has did:key:zIngot registered for region eu-central-3",
		},
	}

	for desc, tc := range cases {
		t.Run(desc, func(t *testing.T) {
			plan := PlanRemoval(tc.state(), testRemoveRequest())
			if got := strings.Join(plan.Blockers, "; "); !strings.Contains(got, tc.want) {
				t.Errorf("blockers = %q, want one containing %q", got, tc.want)
			}
		})
	}
}

func TestApplyRemovalWritesInPlanOrder(t *testing.T) {
	fakes := newRemoveFakes()
	req := testRemoveRequest()

	if _, err := ApplyRemoval(context.Background(), fakes.deps(), req, PlanRemoval(registeredState(), req)); err != nil {
		t.Fatal(err)
	}

	want := []string{
		"hilt set did:key:zIngot did:key:zOther",
		"sprue deregister did:key:zPiri",
		"allow list remove did:key:zPiri",
		"provider info remove did:key:zPiri",
		"record remove us-east-9 did:key:zPiri",
	}
	if !reflect.DeepEqual(*fakes.calls, want) {
		t.Errorf("calls = %v, want %v", *fakes.calls, want)
	}
}

func TestApplyRemovalWritesNothingWhileBlocked(t *testing.T) {
	fakes := newRemoveFakes()
	req := testRemoveRequest()
	state := registeredState()
	state.RecordedPiris = []string{"did:key:zPiri"}

	_, err := ApplyRemoval(context.Background(), fakes.deps(), req, PlanRemoval(state, req))

	got := struct {
		Refused bool
		Calls   []string
	}{err != nil, *fakes.calls}
	if !got.Refused || len(got.Calls) != 0 {
		t.Errorf("refused, calls = %+v, want refused with no calls", got)
	}
}

// A run that finds nothing left to remove succeeds without writing, so a run
// that failed halfway can be repeated.
func TestApplyRemovalOfAnAbsentPiriWritesNothing(t *testing.T) {
	fakes := newRemoveFakes()
	req := testRemoveRequest()
	plan := PlanRemoval(&RemoveState{Region: req.Region, PiriDID: req.PiriDID}, req)

	result, err := ApplyRemoval(context.Background(), fakes.deps(), req, plan)
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Performed) != 0 || len(*fakes.calls) != 0 {
		t.Errorf("performed %v, calls %v, want neither", result.Performed, *fakes.calls)
	}
}

// --- fakes ---

// removeFakes record every write into one shared log, so a test can assert the
// order across services.
type removeFakes struct {
	calls        *[]string
	allowList    *fakeRemovableAllowList
	sprue        *fakeDeregisterableSprue
	hilt         *fakeRemoveHilt
	providerInfo *fakeProviderInfo
	record       *fakeRemovableRecord
}

func newRemoveFakes() *removeFakes {
	calls := &[]string{}
	return &removeFakes{
		calls:        calls,
		allowList:    &fakeRemovableAllowList{calls: calls},
		sprue:        &fakeDeregisterableSprue{calls: calls},
		hilt:         &fakeRemoveHilt{calls: calls},
		providerInfo: &fakeProviderInfo{calls: calls},
		record:       &fakeRemovableRecord{calls: calls},
	}
}

func (f *removeFakes) deps() RemoveDeps {
	return RemoveDeps{
		AllowList:    f.allowList,
		Sprue:        f.sprue,
		Hilt:         f.hilt,
		ProviderInfo: f.providerInfo,
		PiriRecord:   f.record,
	}
}

type fakeRemovableAllowList struct {
	calls *[]string
	has   bool
}

func (a *fakeRemovableAllowList) Has(_ context.Context, _ string) (bool, error) { return a.has, nil }

func (a *fakeRemovableAllowList) Remove(_ context.Context, did string) error {
	*a.calls = append(*a.calls, "allow list remove "+did)
	return nil
}

type fakeDeregisterableSprue struct {
	calls    *[]string
	provider *Provider
}

func (s *fakeDeregisterableSprue) Provider(_ context.Context, _ string) (*Provider, error) {
	return s.provider, nil
}

func (s *fakeDeregisterableSprue) Deregister(_ context.Context, did string) error {
	*s.calls = append(*s.calls, "sprue deregister "+did)
	return nil
}

type fakeRemoveHilt struct {
	calls  *[]string
	region string
	policy string
}

func (h *fakeRemoveHilt) Provider(_ context.Context, _ string) (*HiltProvider, error) {
	if h.region == "" {
		return nil, nil
	}
	return &HiltProvider{Region: h.region, Policy: h.policy}, nil
}

func (h *fakeRemoveHilt) AddProvider(_ context.Context, did, region string, nodes []string) error {
	*h.calls = append(*h.calls, "hilt add "+did)
	return nil
}

func (h *fakeRemoveHilt) SetProviderNodes(_ context.Context, did string, nodes []string) error {
	*h.calls = append(*h.calls, "hilt set "+did+" "+strings.Join(nodes, " "))
	return nil
}

type fakeProviderInfo struct {
	calls *[]string
	has   bool
}

func (p *fakeProviderInfo) Has(_ context.Context, _ string) (bool, error) { return p.has, nil }

func (p *fakeProviderInfo) Remove(_ context.Context, did string) error {
	*p.calls = append(*p.calls, "provider info remove "+did)
	return nil
}

type fakeRemovableRecord struct {
	calls    *[]string
	recorded []string
	regions  []string
}

func (r *fakeRemovableRecord) Recorded(_ context.Context, _ string) ([]string, error) {
	return r.recorded, nil
}

func (r *fakeRemovableRecord) Regions(_ context.Context, _ string) ([]string, error) {
	return r.regions, nil
}

func (r *fakeRemovableRecord) Remove(_ context.Context, region, did string) error {
	*r.calls = append(*r.calls, "record remove "+region+" "+did)
	return nil
}
