package vaultinit

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/openbao/openbao/api/v2"
)

// This file mints the credential a regional appliance authenticates with to
// unseal, per fil-one/RFC#21: an orphan periodic token, bound to the node's
// egress address, carrying only that region's transit policy.
//
// Minting goes through a token role rather than auth/token/create-orphan, and
// that is not a stylistic choice. OpenBao's token store takes a new token's
// bound CIDRs from its role, or inherits them from its parent; the create
// endpoints have no CIDR parameter at all, and an orphan token has no parent to
// inherit from. Passing token_bound_cidrs to create-orphan is accepted and
// ignored, which yields a token usable from anywhere.

// ApplianceTokenConfig is what a region's token role is written with.
type ApplianceTokenConfig struct {
	// Region label, naming both the policy and the role.
	Region string
	// NodeCIDR is the node's egress address, normally its Elastic IP as a /32.
	// A token bound to it is worthless anywhere else, which is what makes an
	// imaged disk replayed elsewhere fail to unseal.
	NodeCIDR string
	// Period is how long the node may fail to renew before the token dies. It
	// renews forever, so this is a tolerance for outages rather than a lifetime.
	Period string
}

// EnsureApplianceTokenRole writes the token role a region's unseal token is
// minted from.
//
// The role is written at mint time rather than when the transit key is created,
// because its CIDR is the node's Elastic IP and that address does not exist
// until the node's own apply has run.
func EnsureApplianceTokenRole(ctx context.Context, client *api.Client, cfg ApplianceTokenConfig) error {
	if cfg.NodeCIDR == "" {
		return fmt.Errorf("a node CIDR is required; a role without one mints tokens usable from anywhere")
	}

	name := ApplianceKeyName(cfg.Region)
	role := map[string]any{
		"orphan":            true,
		"allowed_policies":  []string{name},
		"token_period":      cfg.Period,
		"token_bound_cidrs": []string{cfg.NodeCIDR},
		// The region's own policy grants renew-self and lookup-self, so the
		// token needs nothing from the default policy and is given none of it.
		"token_no_default_policy": true,
		"renewable":               true,
	}

	if _, err := client.Logical().WriteWithContext(ctx, applianceRolePath(name), role); err != nil {
		return fmt.Errorf("write token role %s: %w", name, err)
	}
	return nil
}

// MintApplianceToken issues the region's unseal token, wrapped.
//
// What comes back is a single-use wrapping token with a short TTL, not the token
// itself. The real token stays inside OpenBao until the node unwraps it, so it
// never transits the channel that carries the hand-off to a node operator, and
// an interception makes the node's own unwrap fail rather than passing unnoticed.
//
// The returned accessor belongs to the wrapped token and is what revocation and
// liveness checks use later. It cannot authenticate.
func MintApplianceToken(ctx context.Context, client *api.Client, cfg ApplianceTokenConfig, wrapTTL string) (wrappingToken, accessor string, err error) {
	if wrapTTL == "" {
		return "", "", fmt.Errorf("a wrapping TTL is required; without one the token comes back in the clear")
	}

	name := ApplianceKeyName(cfg.Region)

	// Wrapping is requested per call, through a header the client adds when its
	// lookup function returns a TTL. The function answers for every request the
	// client makes, so it goes on a clone used for this one call and nothing
	// else; setting it on the caller's client would wrap unrelated requests.
	wrapped, err := client.Clone()
	if err != nil {
		return "", "", fmt.Errorf("clone the openbao client: %w", err)
	}
	wrapped.SetToken(client.Token())
	wrapped.SetWrappingLookupFunc(func(operation, path string) string { return wrapTTL })

	// The role's allowed_policies would supply the same set when a request
	// names none, but that is a fallback inside OpenBao's token store. Naming
	// the policy makes the request itself say what the token carries.
	resp, err := wrapped.Logical().WriteWithContext(ctx, "auth/token/create/"+name, map[string]any{
		"display_name": name,
		"policies":     []string{name},
		"meta":         map[string]string{"region": cfg.Region},
	})
	if err != nil {
		return "", "", fmt.Errorf("mint the %s unseal token: %w", cfg.Region, err)
	}
	if resp == nil || resp.WrapInfo == nil {
		return "", "", refuseUnwrappedToken(ctx, client, cfg.Region, resp)
	}

	return resp.WrapInfo.Token, resp.WrapInfo.WrappedAccessor, nil
}

// refuseUnwrappedToken turns a response that came back unwrapped into an error,
// revoking the token it carries on the way out.
//
// The create has already succeeded by this point, so the response holds a live
// credential with the region's policy. Returning the error alone would drop its
// accessor, leaving a token nothing can revoke and an operator whose retry mints
// a second one.
func refuseUnwrappedToken(ctx context.Context, client *api.Client, region string, resp *api.Secret) error {
	refusal := fmt.Errorf("the %s unseal token came back unwrapped; refusing to return it", region)
	if resp == nil || resp.Auth == nil || resp.Auth.Accessor == "" {
		return refusal
	}

	if err := RevokeTokenByAccessor(ctx, client, resp.Auth.Accessor); err != nil {
		// Naming the accessor is what lets an operator finish the job by hand.
		return fmt.Errorf("%w, and revoking it failed; revoke accessor %s: %w",
			refusal, resp.Auth.Accessor, err)
	}
	return refusal
}

// TokenLive reports whether the token behind an accessor still exists.
//
// An accessor OpenBao no longer knows is an answer rather than a problem: an
// accessor outlives the token it names, so a recorded accessor whose token has
// expired is the ordinary state of a node that has been offline past its period.
//
// Every other failure is returned. A caller decides whether to mint from this,
// and a timeout reported as "not live" would mint a second standing credential
// for a node that already has one.
func TokenLive(ctx context.Context, client *api.Client, accessor string) (bool, error) {
	secret, err := client.Auth().Token().LookupAccessorWithContext(ctx, accessor)
	switch {
	case err == nil:
		return secret != nil, nil
	case isUnknownAccessor(err):
		return false, nil
	default:
		return false, fmt.Errorf("look up token %s: %w", accessor, err)
	}
}

// RevokeTokenByAccessor revokes a token and treats an accessor OpenBao no longer
// knows as success.
//
// The caller's goal is that no live token remains, and an already-dead token
// meets it. Failing here instead would deadlock retiring a region: the common
// case for retirement is a node that has been offline long enough for its token
// to lapse, and a phase that errored on that could never get past it.
func RevokeTokenByAccessor(ctx context.Context, client *api.Client, accessor string) error {
	err := client.Auth().Token().RevokeAccessorWithContext(ctx, accessor)
	if err == nil || isUnknownAccessor(err) {
		return nil
	}
	return fmt.Errorf("revoke token %s: %w", accessor, err)
}

// RemoveApplianceTokenRole deletes a region's token role, so nothing can mint
// against it after the region is retired.
func RemoveApplianceTokenRole(ctx context.Context, client *api.Client, region string) error {
	path := applianceRolePath(ApplianceKeyName(region))
	if _, err := client.Logical().DeleteWithContext(ctx, path); err != nil {
		return fmt.Errorf("delete token role %s: %w", path, err)
	}
	return nil
}

func isUnknownAccessor(err error) bool {
	var respErr *api.ResponseError
	if !errors.As(err, &respErr) {
		return false
	}
	if respErr.StatusCode == 404 {
		return true
	}
	// An accessor whose token has gone is reported as a 400 naming the accessor
	// rather than as a not-found.
	for _, message := range respErr.Errors {
		if strings.Contains(message, "invalid accessor") {
			return true
		}
	}
	return false
}

func applianceRolePath(name string) string {
	return "auth/token/roles/" + name
}
