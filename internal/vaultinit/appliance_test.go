package vaultinit

import (
	"context"
	"reflect"
	"strings"
	"testing"
)

func TestPlanApplianceKeysEnsuresEveryLiveRegion(t *testing.T) {
	plan, err := PlanApplianceKeys(nil, []string{"us-east-9", "eu-central-3"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	want := AppliancePlan{Active: []string{"us-east-9", "eu-central-3"}}
	if !reflect.DeepEqual(plan, want) {
		t.Errorf("PlanApplianceKeys() = %+v, want %+v", plan, want)
	}
}

func TestPlanApplianceKeysRemovesARetiredRegionThatStillHasAKey(t *testing.T) {
	plan, err := PlanApplianceKeys([]string{"eu-central-3", "us-east-9"}, []string{"us-east-9"}, []string{"eu-central-3"})
	if err != nil {
		t.Fatal(err)
	}
	want := AppliancePlan{Active: []string{"us-east-9"}, Remove: []string{"eu-central-3"}}
	if !reflect.DeepEqual(plan, want) {
		t.Errorf("PlanApplianceKeys() = %+v, want %+v", plan, want)
	}
}

// A region retired before its key was ever created is not an error; there is
// simply nothing left to destroy.
func TestPlanApplianceKeysIgnoresARetiredRegionWithNoKey(t *testing.T) {
	plan, err := PlanApplianceKeys(nil, nil, []string{"eu-central-3"})
	if err != nil {
		t.Fatal(err)
	}
	if len(plan.Remove) != 0 {
		t.Errorf("plan.Remove = %v, want none", plan.Remove)
	}
}

// The check that makes automated removal safe: a key nobody accounted for is a
// typo or a rename, and destroying it would brick a live node.
func TestPlanApplianceKeysRejectsAKeyInNeitherList(t *testing.T) {
	_, err := PlanApplianceKeys([]string{"us-east-9"}, []string{"us-east-8"}, nil)
	if err == nil || !strings.Contains(err.Error(), "us-east-9") {
		t.Fatalf("PlanApplianceKeys() error = %v, want one naming us-east-9", err)
	}
}

func TestPlanApplianceKeysRejectsARegionInBothLists(t *testing.T) {
	_, err := PlanApplianceKeys(nil, []string{"us-east-9"}, []string{"us-east-9"})
	if err == nil || !strings.Contains(err.Error(), "both") {
		t.Fatalf("PlanApplianceKeys() error = %v, want one naming both lists", err)
	}
}

func TestEnsureApplianceTransitKeysCreatesAMissingKey(t *testing.T) {
	f := &fakeOpenBao{initialised: true}
	client := newClient(t, f)

	created, err := EnsureApplianceTransitKeys(context.Background(), client, []string{"us-east-9"})
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"appliance-unseal-us-east-9"}; !reflect.DeepEqual(created, want) {
		t.Errorf("created = %v, want %v", created, want)
	}
}

func TestEnsureApplianceTransitKeysLeavesAnExistingKeyAlone(t *testing.T) {
	f := &fakeOpenBao{initialised: true, transitKeys: map[string]bool{"appliance-unseal-us-east-9": true}}
	client := newClient(t, f)

	created, err := EnsureApplianceTransitKeys(context.Background(), client, []string{"us-east-9"})
	if err != nil {
		t.Fatal(err)
	}
	if len(created) != 0 {
		t.Errorf("created = %v, want none", created)
	}
}

// The policy is the node's whole authority, so what it grants is worth pinning.
func TestEnsureApplianceTransitKeysGrantsOnlyTheRegionsOwnTransitPaths(t *testing.T) {
	f := &fakeOpenBao{initialised: true}
	client := newClient(t, f)

	if _, err := EnsureApplianceTransitKeys(context.Background(), client, []string{"us-east-9"}); err != nil {
		t.Fatal(err)
	}

	policy := f.policies["appliance-unseal-us-east-9"]
	for _, want := range []string{
		`path "transit/encrypt/appliance-unseal-us-east-9"`,
		`path "transit/decrypt/appliance-unseal-us-east-9"`,
		`path "auth/token/renew-self"`,
	} {
		if !strings.Contains(policy, want) {
			t.Errorf("policy is missing %s; got:\n%s", want, policy)
		}
	}
	if strings.Contains(policy, "transit/keys") {
		t.Errorf("policy reaches the key itself; got:\n%s", policy)
	}
}

func TestRemoveApplianceTransitKeyDeletesThePolicyAndTheKey(t *testing.T) {
	f := &fakeOpenBao{initialised: true, transitKeys: map[string]bool{"appliance-unseal-eu-central-3": true}}
	client := newClient(t, f)

	if err := RemoveApplianceTransitKey(context.Background(), client, "eu-central-3"); err != nil {
		t.Fatal(err)
	}
	if f.transitKeys["appliance-unseal-eu-central-3"] {
		t.Error("the transit key survived the removal")
	}
	if want := []string{"appliance-unseal-eu-central-3"}; !reflect.DeepEqual(f.deletedPolicies, want) {
		t.Errorf("deleted policies = %v, want %v", f.deletedPolicies, want)
	}
}

// OpenBao refuses to delete a transit key until its config allows it, so the
// flag has to be set first or the delete fails on a live key.
func TestRemoveApplianceTransitKeyAllowsDeletionFirst(t *testing.T) {
	f := &fakeOpenBao{initialised: true, transitKeys: map[string]bool{"appliance-unseal-eu-central-3": true}}
	client := newClient(t, f)

	if err := RemoveApplianceTransitKey(context.Background(), client, "eu-central-3"); err != nil {
		t.Fatal(err)
	}
	if !f.deletionAllowed["appliance-unseal-eu-central-3"] {
		t.Error("deletion was never allowed on the key")
	}
}

func TestApplianceRegionsReportsOnlyApplianceKeys(t *testing.T) {
	f := &fakeOpenBao{initialised: true, transitKeys: map[string]bool{
		"appliance-unseal-us-east-9":    true,
		"appliance-unseal-eu-central-3": true,
		"something-else":                true,
	}}
	client := newClient(t, f)

	regions, err := ApplianceRegions(context.Background(), client)
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"eu-central-3", "us-east-9"}; !reflect.DeepEqual(regions, want) {
		t.Errorf("ApplianceRegions() = %v, want %v", regions, want)
	}
}

// An empty transit mount is the normal state of a stage with no appliances, and
// OpenBao reports it as an empty list rather than an error.
func TestApplianceRegionsHandlesAnEmptyMount(t *testing.T) {
	client := newClient(t, &fakeOpenBao{initialised: true})

	regions, err := ApplianceRegions(context.Background(), client)
	if err != nil {
		t.Fatal(err)
	}
	if len(regions) != 0 {
		t.Errorf("ApplianceRegions() = %v, want none", regions)
	}
}
