package vaultinit

import (
	"context"
	"reflect"
	"strings"
	"testing"
)

// The CIDR bound to the role is the token's only network boundary, because the
// create endpoint has none: a role written without it mints tokens usable from
// anywhere.
func TestEnsureApplianceTokenRoleBindsTheNodeCIDR(t *testing.T) {
	f := &fakeOpenBao{initialised: true}
	client := newClient(t, f)

	err := EnsureApplianceTokenRole(context.Background(), client, ApplianceTokenConfig{
		Region:   "us-east-9",
		NodeCIDR: "203.0.113.7/32",
		Period:   "72h",
	})
	if err != nil {
		t.Fatal(err)
	}

	got := f.tokenRoles["appliance-unseal-us-east-9"]
	if want := []any{"203.0.113.7/32"}; !reflect.DeepEqual(got["token_bound_cidrs"], want) {
		t.Errorf("token_bound_cidrs = %v, want %v", got["token_bound_cidrs"], want)
	}
}

func TestEnsureApplianceTokenRoleRefusesAnEmptyCIDR(t *testing.T) {
	client := newClient(t, &fakeOpenBao{initialised: true})

	err := EnsureApplianceTokenRole(context.Background(), client, ApplianceTokenConfig{
		Region: "us-east-9",
		Period: "72h",
	})
	if err == nil || !strings.Contains(err.Error(), "anywhere") {
		t.Fatalf("EnsureApplianceTokenRole() error = %v, want a refusal naming the risk", err)
	}
}

// Orphan so revoking an operator's token does not cascade into the node, and
// periodic so it renews forever with no expiry cliff.
func TestEnsureApplianceTokenRoleIsOrphanAndPeriodic(t *testing.T) {
	f := &fakeOpenBao{initialised: true}
	client := newClient(t, f)

	err := EnsureApplianceTokenRole(context.Background(), client, ApplianceTokenConfig{
		Region:   "us-east-9",
		NodeCIDR: "203.0.113.7/32",
		Period:   "72h",
	})
	if err != nil {
		t.Fatal(err)
	}

	role := f.tokenRoles["appliance-unseal-us-east-9"]
	got := map[string]any{
		"orphan":                  role["orphan"],
		"token_period":            role["token_period"],
		"token_no_default_policy": role["token_no_default_policy"],
		"allowed_policies":        role["allowed_policies"],
	}
	want := map[string]any{
		"orphan":                  true,
		"token_period":            "72h",
		"token_no_default_policy": true,
		"allowed_policies":        []any{"appliance-unseal-us-east-9"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("role = %v, want %v", got, want)
	}
}

func TestMintApplianceTokenReturnsTheWrappingTokenAndAccessor(t *testing.T) {
	f := &fakeOpenBao{initialised: true}
	client := newClient(t, f)

	token, accessor, err := MintApplianceToken(context.Background(), client, ApplianceTokenConfig{
		Region:   "us-east-9",
		NodeCIDR: "203.0.113.7/32",
		Period:   "72h",
	}, "24h")
	if err != nil {
		t.Fatal(err)
	}
	if got := []string{token, accessor}; !reflect.DeepEqual(got, []string{"wrap-1", "acc-1"}) {
		t.Errorf("MintApplianceToken() = %v, want [wrap-1 acc-1]", got)
	}
}

// The role's allowed_policies would fill the policies in when a request names
// none, but that is a fallback the request should not lean on.
func TestMintApplianceTokenNamesTheRegionPolicy(t *testing.T) {
	f := &fakeOpenBao{initialised: true}
	client := newClient(t, f)

	if _, _, err := MintApplianceToken(context.Background(), client, ApplianceTokenConfig{
		Region: "us-east-9",
	}, "24h"); err != nil {
		t.Fatal(err)
	}

	want := []any{"appliance-unseal-us-east-9"}
	if got := f.tokenCreateBody["policies"]; !reflect.DeepEqual(got, want) {
		t.Errorf("policies = %v, want %v", got, want)
	}
}

// The wrap is the whole reason the real token never reaches the operator, so an
// unwrapped response is a failure rather than something to pass along.
func TestMintApplianceTokenRefusesAnUnwrappedResponse(t *testing.T) {
	f := &fakeOpenBao{initialised: true, refuseToWrap: true}
	client := newClient(t, f)

	_, _, err := MintApplianceToken(context.Background(), client, ApplianceTokenConfig{
		Region:   "us-east-9",
		NodeCIDR: "203.0.113.7/32",
	}, "24h")
	if err == nil || !strings.Contains(err.Error(), "unwrapped") {
		t.Fatalf("MintApplianceToken() error = %v, want a refusal to return it", err)
	}
}

func TestMintApplianceTokenAsksForTheWrapTTL(t *testing.T) {
	f := &fakeOpenBao{initialised: true}
	client := newClient(t, f)

	if _, _, err := MintApplianceToken(context.Background(), client, ApplianceTokenConfig{
		Region: "us-east-9",
	}, "1h"); err != nil {
		t.Fatal(err)
	}
	if f.wrapTTLSeen != "1h" {
		t.Errorf("wrap TTL header = %q, want %q", f.wrapTTLSeen, "1h")
	}
}

func TestTokenLiveReportsAKnownAccessor(t *testing.T) {
	client := newClient(t, &fakeOpenBao{initialised: true, accessorKnown: true})

	if !TokenLive(context.Background(), client, "acc-1") {
		t.Error("TokenLive() = false, want true")
	}
}

func TestTokenLiveReportsALapsedAccessor(t *testing.T) {
	client := newClient(t, &fakeOpenBao{initialised: true})

	if TokenLive(context.Background(), client, "acc-gone") {
		t.Error("TokenLive() = true, want false")
	}
}

func TestRevokeTokenByAccessorRevokesALiveToken(t *testing.T) {
	f := &fakeOpenBao{initialised: true, accessorKnown: true}
	client := newClient(t, f)

	if err := RevokeTokenByAccessor(context.Background(), client, "acc-1"); err != nil {
		t.Fatal(err)
	}
	if want := []string{"acc-1"}; !reflect.DeepEqual(f.revokedAccessors, want) {
		t.Errorf("revoked = %v, want %v", f.revokedAccessors, want)
	}
}

// Retiring a region normally means a node that has been offline past its period,
// so its token is already gone. Failing on that would make retirement
// impossible to complete on the one path that matters most.
func TestRevokeTokenByAccessorToleratesALapsedToken(t *testing.T) {
	client := newClient(t, &fakeOpenBao{initialised: true})

	if err := RevokeTokenByAccessor(context.Background(), client, "acc-gone"); err != nil {
		t.Fatalf("RevokeTokenByAccessor() error = %v, want nil for an accessor already gone", err)
	}
}
