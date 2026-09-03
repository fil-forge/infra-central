package onboard

import (
	"context"
	"reflect"
	"strings"
	"testing"
)

func testRequest() Request {
	return Request{
		Region:            "us-east-9",
		PiriDID:           "did:key:zPiri",
		IngotDID:          "did:key:zIngot",
		PiriURL:           "https://piri.dev.forge-sandbox.fil.one",
		PiriProof:         []byte("proof-bytes"),
		Weight:            100,
		ReplicationWeight: 100,
	}
}

func TestReadReportsAFreshAppliance(t *testing.T) {
	deps := newFakes()

	state, err := Read(context.Background(), deps.deps(), testRequest())
	if err != nil {
		t.Fatal(err)
	}
	want := &State{Region: "us-east-9", AllowListed: false, Sprue: nil, HiltRegion: "", PiriRecorded: false}
	if !reflect.DeepEqual(state, want) {
		t.Errorf("Read() = %+v, want %+v", state, want)
	}
}

func TestPlanFromListsEveryWriteInApplyOrderForAFreshAppliance(t *testing.T) {
	plan := PlanFrom(&State{Region: "us-east-9"}, testRequest())

	want := []string{
		"add did:key:zPiri to the delegator's allow list",
		"register did:key:zPiri with sprue at https://piri.dev.forge-sandbox.fil.one",
		"set did:key:zPiri's weights to 100 and 100",
		"register did:key:zIngot with hilt for region us-east-9",
		"record did:key:zPiri as a Piri of region us-east-9",
	}
	if !reflect.DeepEqual(plan.Actions, want) {
		t.Errorf("actions = %v, want %v", plan.Actions, want)
	}
}

func TestPlanFromPlansNothingForARegisteredAppliance(t *testing.T) {
	req := testRequest()
	state := &State{
		Region:       req.Region,
		AllowListed:  true,
		Sprue:        &Provider{Endpoint: req.PiriURL, Weight: 100, ReplicationWeight: 100},
		HiltRegion:   req.Region,
		PiriRecorded: true,
	}

	plan := PlanFrom(state, req)

	if len(plan.Actions) != 0 || len(plan.Blockers) != 0 {
		t.Errorf("plan = %+v, want no actions and no blockers", plan)
	}
}

// The weights are two integers from the request, so a provider carrying
// different ones is repaired rather than left alone.
func TestPlanFromResetsMismatchedWeights(t *testing.T) {
	req := testRequest()
	state := &State{
		Region:       req.Region,
		AllowListed:  true,
		Sprue:        &Provider{Endpoint: req.PiriURL, Weight: 1, ReplicationWeight: 1},
		HiltRegion:   req.Region,
		PiriRecorded: true,
	}

	plan := PlanFrom(state, req)

	if len(plan.Actions) != 1 || !strings.Contains(plan.Actions[0], "weights") {
		t.Errorf("actions = %v, want only a weight change", plan.Actions)
	}
}

// This is the failure smelt's tolerance of "already registered" once masked:
// hilt reports the same error for a DID held under a different region, and has
// no command to move one.
func TestPlanFromBlocksAHiltRegionMismatch(t *testing.T) {
	req := testRequest()
	state := &State{
		Region:      req.Region,
		AllowListed: true,
		Sprue:       &Provider{Endpoint: req.PiriURL, Weight: 100, ReplicationWeight: 100},
		HiltRegion:  "eu-central-3",
	}

	plan := PlanFrom(state, req)

	if len(plan.Blockers) != 1 || !strings.Contains(plan.Blockers[0], "eu-central-3") {
		t.Errorf("blockers = %v, want one naming the region it is registered for", plan.Blockers)
	}
}

// Re-registering at a different endpoint moves where uploads are sent, so it is
// a decision rather than a repair.
func TestPlanFromBlocksASprueEndpointMismatch(t *testing.T) {
	req := testRequest()
	state := &State{
		Region:      req.Region,
		AllowListed: true,
		Sprue:       &Provider{Endpoint: "https://piri.old.example", Weight: 100, ReplicationWeight: 100},
		HiltRegion:  req.Region,
	}

	plan := PlanFrom(state, req)

	if len(plan.Blockers) != 1 || !strings.Contains(plan.Blockers[0], "piri.old.example") {
		t.Errorf("blockers = %v, want one naming the endpoint on record", plan.Blockers)
	}
}

func TestApplyRefusesAPlanWithBlockers(t *testing.T) {
	fakes := newFakes()
	plan := &Plan{Blockers: []string{"hilt has it in another region"}}

	if _, err := Apply(context.Background(), fakes.deps(), testRequest(), plan); err == nil {
		t.Fatal("Apply() returned no error for a blocked plan")
	}
	if fakes.allowList.added != "" {
		t.Errorf("a blocked plan wrote %q to the allow list", fakes.allowList.added)
	}
}

func TestApplyPerformsEveryWriteForAFreshAppliance(t *testing.T) {
	fakes := newFakes()
	req := testRequest()
	plan := PlanFrom(&State{Region: req.Region}, req)

	result, err := Apply(context.Background(), fakes.deps(), req, plan)
	if err != nil {
		t.Fatal(err)
	}

	got := map[string]any{
		"allowListed":  fakes.allowList.added,
		"sprueDID":     fakes.sprue.registeredDID,
		"sprueProof":   string(fakes.sprue.registeredProof),
		"hiltRegion":   fakes.hilt.region,
		"weight":       fakes.sprue.weight,
		"piriRecord":   fakes.piri.added,
		"proofReturns": result.HiltIngotS3Proof,
	}
	want := map[string]any{
		"allowListed":  "did:key:zPiri",
		"sprueDID":     "did:key:zPiri",
		"sprueProof":   "proof-bytes",
		"hiltRegion":   "us-east-9",
		"weight":       100,
		"piriRecord":   "us-east-9 did:key:zPiri",
		"proofReturns": "the-proof",
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("Apply() performed %v, want %v", got, want)
	}
}

// hilt answers "already registered" for a DID held under another region as well
// as for this one, so the row it leaves behind is the only real evidence.
func TestApplyFailsWhenHiltsRowDisagreesAfterTheWrite(t *testing.T) {
	fakes := newFakes()
	fakes.hilt.regionAfterAdd = "eu-central-3"
	req := testRequest()
	plan := PlanFrom(&State{Region: req.Region}, req)

	_, err := Apply(context.Background(), fakes.deps(), req, plan)
	if err == nil || !strings.Contains(err.Error(), "eu-central-3") {
		t.Fatalf("Apply() error = %v, want one naming the region hilt actually recorded", err)
	}
}

// Registering with sprue is the one write that needs something only the
// appliance can produce, so a request without it is a blocker the dry run
// reports rather than an error the writes run into.
func TestPlanFromBlocksAFreshApplianceWithoutThePiriProof(t *testing.T) {
	req := testRequest()
	req.PiriProof = nil

	plan := PlanFrom(&State{Region: req.Region}, req)

	if len(plan.Blockers) != 1 || !strings.Contains(plan.Blockers[0], "proof") {
		t.Fatalf("blockers = %v, want one naming the missing proof", plan.Blockers)
	}
}

func TestApplyWritesNothingWithoutThePiriProof(t *testing.T) {
	fakes := newFakes()
	req := testRequest()
	req.PiriProof = nil
	plan := PlanFrom(&State{Region: req.Region}, req)

	if _, err := Apply(context.Background(), fakes.deps(), req, plan); err == nil {
		t.Fatal("Apply() error = nil, want one naming the missing proof")
	}
	if fakes.allowList.added != "" {
		t.Errorf("allow-listed %q, want nothing written", fakes.allowList.added)
	}
}

// A second run must not need the proof again, because sprue already holds the
// provider and nothing is re-registered.
func TestApplyNeedsNoProofWhenSprueAlreadyHoldsTheProvider(t *testing.T) {
	fakes := newFakes()
	req := testRequest()
	req.PiriProof = nil
	state := &State{
		Region:       req.Region,
		AllowListed:  true,
		Sprue:        &Provider{Endpoint: req.PiriURL, Weight: 100, ReplicationWeight: 100},
		HiltRegion:   req.Region,
		PiriRecorded: true,
	}

	if _, err := Apply(context.Background(), fakes.deps(), req, PlanFrom(state, req)); err != nil {
		t.Fatalf("Apply() error = %v, want nil", err)
	}
}

func TestApplyReturnsTheProofOnEveryRun(t *testing.T) {
	fakes := newFakes()
	req := testRequest()
	state := &State{
		Region:       req.Region,
		AllowListed:  true,
		Sprue:        &Provider{Endpoint: req.PiriURL, Weight: 100, ReplicationWeight: 100},
		HiltRegion:   req.Region,
		PiriRecorded: true,
	}

	result, err := Apply(context.Background(), fakes.deps(), req, PlanFrom(state, req))
	if err != nil {
		t.Fatal(err)
	}
	if result.HiltIngotS3Proof != "the-proof" {
		t.Errorf("proof = %q, want it returned even when nothing was written", result.HiltIngotS3Proof)
	}
}

// --- fakes ---

type fakes struct {
	allowList *fakeAllowList
	sprue     *fakeSprue
	hilt      *fakeHilt
	piri      *fakePiriRecord
}

func newFakes() *fakes {
	return &fakes{
		allowList: &fakeAllowList{},
		sprue:     &fakeSprue{},
		hilt:      &fakeHilt{},
		piri:      &fakePiriRecord{},
	}
}

func (f *fakes) deps() Deps {
	return Deps{
		AllowList: f.allowList,
		Sprue:     f.sprue,
		Hilt:      f.hilt,
		IssueProof: func(ctx context.Context, region, ingotDID string) (string, error) {
			return "the-proof", nil
		},
		PiriRecord: f.piri,
	}
}

type fakeAllowList struct {
	has   bool
	added string
}

func (a *fakeAllowList) Has(ctx context.Context, did string) (bool, error) { return a.has, nil }

func (a *fakeAllowList) Add(ctx context.Context, did string) error {
	a.added = did
	return nil
}

type fakeSprue struct {
	provider *Provider

	registeredDID   string
	registeredProof []byte
	weight          int
}

func (s *fakeSprue) Provider(ctx context.Context, did string) (*Provider, error) {
	return s.provider, nil
}

func (s *fakeSprue) Register(ctx context.Context, did, endpoint string, proof []byte) error {
	s.registeredDID = did
	s.registeredProof = proof
	return nil
}

func (s *fakeSprue) SetWeight(ctx context.Context, did string, weight, replicationWeight int) error {
	s.weight = weight
	return nil
}

type fakeHilt struct {
	region string
	// regionAfterAdd is what the row says once AddProvider has run, which is how
	// a region mismatch is simulated.
	regionAfterAdd string
	added          bool
}

type fakePiriRecord struct {
	recorded []string
	added    string
}

func (p *fakePiriRecord) Recorded(_ context.Context, _ string) ([]string, error) {
	return p.recorded, nil
}

func (p *fakePiriRecord) Record(_ context.Context, region, piriDID string) error {
	p.added = region + " " + piriDID
	return nil
}

func (h *fakeHilt) ProviderRegion(ctx context.Context, did string) (string, error) {
	if h.added && h.regionAfterAdd != "" {
		return h.regionAfterAdd, nil
	}
	return h.region, nil
}

func (h *fakeHilt) AddProvider(ctx context.Context, did, region string) error {
	h.added = true
	h.region = region
	return nil
}
