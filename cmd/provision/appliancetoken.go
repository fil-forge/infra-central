package main

import (
	"context"
	"fmt"
	"log/slog"

	"github.com/hashicorp/go-secure-stdlib/parseutil"
	"github.com/openbao/openbao/api/v2"

	"github.com/fil-forge/infra-central/internal/vaultinit"
)

// Defaults for the unseal token.
const (
	// defaultTokenPeriod is how long a node may fail to renew before its token
	// dies and the delivery ceremony has to be repeated. The node renews hourly,
	// so this is a tolerance for outages: three days covers a weekend at the
	// operator's site, and a node that is abandoned still fails closed within
	// days. Revocation is immediate at any period, so a longer one buys the
	// operator convenience without costing containment.
	defaultTokenPeriod = "72h"

	// defaultWrapTTL bounds how long the hand-off may sit unclaimed. Long enough
	// for a delivery across time zones, short enough that an unnoticed leak
	// expires on its own.
	defaultWrapTTL = "24h"
)

// applianceToken issues the credential a regional appliance unseals with.
//
// Terraform never invokes this phase, and it is the one phase that must not be.
// Every other response here is public by construction, documented as safe for
// anyone with state access; this one carries a wrapping token that exchanges for
// a live credential, and an aws_lambda_invocation would write it into Terraform
// state. The caller is an operator running scripts/mint-appliance-token.sh.
//
// What is returned is wrapped rather than the token itself, so the credential
// never transits the channel that carries it to a node operator. See
// docs/decisions/2026-08-region-onboarding.md.
func (d *deps) applianceToken(ctx context.Context, req Request) (*Response, error) {
	if req.Region == "" {
		return nil, fmt.Errorf("a region is required")
	}
	if d.cfg.OpenBaoAddr == "" {
		return nil, fmt.Errorf("FORGE_OPENBAO_ADDR is required for the appliance-token phase")
	}

	client, err := api.NewClient(&api.Config{Address: d.cfg.OpenBaoAddr})
	if err != nil {
		return nil, fmt.Errorf("build openbao client: %w", err)
	}
	rootToken, err := d.store.GetSecret(ctx, "openbao", "root-token")
	if err != nil {
		return nil, fmt.Errorf("read the openbao root token: %w", err)
	}
	client.SetToken(rootToken)

	plan, err := d.planApplianceToken(ctx, client, req)
	if err != nil {
		return nil, err
	}

	if !req.Confirm {
		slog.Info("appliance token plan prepared", "region", req.Region, "action", plan.Action)
		return &Response{Phase: "appliance-token", DryRun: true, TokenPlan: plan}, nil
	}
	if plan.Action == tokenActionRefuse {
		return nil, fmt.Errorf(
			"region %s already has a live unseal token (accessor %s); pass --reissue to revoke it and mint another",
			req.Region, plan.Accessor)
	}

	return d.mintApplianceToken(ctx, client, req, plan)
}

// Token plan actions, which are also what the script prints.
const (
	tokenActionMint    = "mint"
	tokenActionReissue = "reissue"
	tokenActionRefuse  = "refuse"
)

// TokenPlan is what the dry run reports.
type TokenPlan struct {
	Region string `json:"region"`
	// Action is mint, reissue or refuse.
	Action string `json:"action"`
	// Accessor of the token already on record, if any. Never the token.
	Accessor string `json:"accessor,omitempty"`
	// TokenLive reports whether that recorded token still exists.
	TokenLive bool   `json:"token_live"`
	NodeCIDR  string `json:"node_cidr"`
	Period    string `json:"period"`
	WrapTTL   string `json:"wrap_ttl"`
}

// planApplianceToken reads the state a mint would change and decides what to do.
func (d *deps) planApplianceToken(ctx context.Context, client *api.Client, req Request) (*TokenPlan, error) {
	// The key has to exist first, and it is created by the vault phase from the
	// stage's committed region list. Failing here rather than creating one keeps
	// git the source of truth for which appliances a stage can unseal.
	name := vaultinit.ApplianceKeyName(req.Region)
	key, err := client.Logical().ReadWithContext(ctx, "transit/keys/"+name)
	if err != nil {
		return nil, fmt.Errorf("read transit key %s: %w", name, err)
	}
	if key == nil {
		return nil, fmt.Errorf(
			"no transit key %s: add %q to appliance_regions in the stage's terraform.tfvars and merge, which creates the key and its policy",
			name, req.Region)
	}

	plan := &TokenPlan{
		Region:   req.Region,
		Action:   tokenActionMint,
		NodeCIDR: req.NodeCIDR,
		Period:   valueOr(req.Period, defaultTokenPeriod),
		WrapTTL:  valueOr(req.WrapTTL, defaultWrapTTL),
	}

	if err := validateTokenDurations(plan); err != nil {
		return nil, err
	}

	accessor, found, err := d.store.LookupPublic(ctx, applianceService(req.Region), unsealTokenAccessorKey)
	if err != nil {
		return nil, err
	}
	if !found {
		return plan, nil
	}

	plan.Accessor = accessor
	// A lookup that cannot answer stops the phase rather than falling through to
	// a mint. Treating it as "no token" is how one node ends up with two live
	// credentials and no record of which it is using.
	plan.TokenLive, err = vaultinit.TokenLive(ctx, client, accessor)
	if err != nil {
		return nil, err
	}
	plan.Action = decideTokenAction(plan.TokenLive, req.Reissue)
	return plan, nil
}

// validateTokenDurations refuses an unparseable period or wrap TTL while nothing
// has been changed yet.
//
// OpenBao would reject these values itself, but only once the role write and the
// mint are already under way. Refusing during the dry run is what keeps a typo
// from being discovered halfway through a reissue.
func validateTokenDurations(plan *TokenPlan) error {
	for _, d := range []struct{ flag, value string }{
		{"--period", plan.Period},
		{"--wrap-ttl", plan.WrapTTL},
	} {
		if _, err := parseutil.ParseDurationSecond(d.value); err != nil {
			return fmt.Errorf("%s %q is not a duration openbao accepts: %w", d.flag, d.value, err)
		}
	}
	return nil
}

// decideTokenAction settles what to do about a region that already has an
// accessor on record.
//
// Minting is the one operation in this project that is not idempotent, which is
// what the refusal is for: a second token means two live credentials for one
// node, and nothing afterwards would say which of them the node is using. A
// token that has already lapsed is a different case entirely and needs no flag,
// because a node offline past its renewal period is the ordinary reason for it
// and minting again is the repair.
func decideTokenAction(tokenLive, reissue bool) string {
	switch {
	case !tokenLive:
		return tokenActionMint
	case reissue:
		return tokenActionReissue
	default:
		return tokenActionRefuse
	}
}

// mintApplianceToken writes the region's token role and issues the wrapped token.
//
// A reissue revokes the region's previous token last, once the replacement is
// minted and recorded. Revoking first would leave the appliance with no
// renewable credential every time the role write or the mint that follows it
// failed, and the node would stop being able to unseal at its next restart
// because of a reissue that never produced anything.
func (d *deps) mintApplianceToken(ctx context.Context, client *api.Client, req Request, plan *TokenPlan) (*Response, error) {
	cfg := vaultinit.ApplianceTokenConfig{
		Region:   req.Region,
		NodeCIDR: plan.NodeCIDR,
		Period:   plan.Period,
	}

	slog.Info("writing the appliance token role",
		"region", req.Region, "cidr", plan.NodeCIDR, "period", plan.Period)
	if err := vaultinit.EnsureApplianceTokenRole(ctx, client, cfg); err != nil {
		return nil, err
	}

	slog.Info("minting the unseal token, wrapped", "region", req.Region, "wrap_ttl", plan.WrapTTL)
	wrappingToken, accessor, err := vaultinit.MintApplianceToken(ctx, client, cfg, plan.WrapTTL)
	if err != nil {
		return nil, err
	}

	if err := recordMintedAccessor(ctx, client, d.store, applianceService(req.Region), accessor); err != nil {
		return nil, err
	}

	// The accessor is logged and the token is not. This is the only value in the
	// project that must stay out of CloudWatch.
	slog.Info("minted the unseal token", "region", req.Region, "accessor", accessor)

	if plan.Action == tokenActionReissue {
		slog.Warn("revoking the previous unseal token", "region", req.Region, "accessor", plan.Accessor)
		if err := vaultinit.RevokeTokenByAccessor(ctx, client, plan.Accessor); err != nil {
			// The replacement is live and recorded, so the old accessor is no
			// longer anywhere but here. Naming it is what lets the operator
			// finish the revocation by hand, and the node keeps renewing that
			// token until they do.
			return nil, fmt.Errorf(
				"the %s replacement token was minted and recorded, but the previous one is still live and is no longer on record; revoke accessor %s by hand: %w",
				req.Region, plan.Accessor, err)
		}
	}

	return &Response{
		Phase: "appliance-token",
		TokenResult: &TokenResult{
			Region:        req.Region,
			WrappingToken: wrappingToken,
			Accessor:      accessor,
			WrapTTL:       plan.WrapTTL,
			Period:        plan.Period,
			NodeCIDR:      plan.NodeCIDR,
			// The node unwraps from outside the VPC, so this is the public
			// hostname the ALB serves OpenBao at, the same "ssm." + suffix the
			// openbao module builds in terraform/modules/platform/main.tf.
			// OpenBaoAddr is the in-VPC address only this Lambda can reach.
			UnsealAddress: "https://ssm." + d.cfg.HostnameSuffix,
		},
	}, nil
}

// accessorRecorder writes a minted token's accessor to the parameter store.
type accessorRecorder interface {
	PutPublic(ctx context.Context, service, name, value string) error
}

// recordMintedAccessor records the accessor of a freshly minted token, revoking
// that token if the write fails.
//
// An unrecorded accessor is a token nothing can revoke, which is worse than a
// failed mint the operator can simply run again. Revoking here turns the first
// into the second.
//
// A crash rather than an error between the mint and this write still strands a
// token nothing records, and the operator's retry mints a second one. That one
// needs no clean-up: its wrapping token was returned to nobody, it is bound to
// the node's own address, and unrenewed it dies at the end of its period.
func recordMintedAccessor(ctx context.Context, client *api.Client, store accessorRecorder, service, accessor string) error {
	err := store.PutPublic(ctx, service, unsealTokenAccessorKey, accessor)
	if err == nil {
		return nil
	}

	if revokeErr := vaultinit.RevokeTokenByAccessor(ctx, client, accessor); revokeErr != nil {
		// Naming the accessor is what lets an operator finish the job by hand.
		return fmt.Errorf("record the minted accessor: %w, and revoking accessor %s failed: %w",
			err, accessor, revokeErr)
	}
	return fmt.Errorf("record the minted accessor, so the token was revoked: %w", err)
}

// TokenResult carries the wrapped credential back to the operator.
//
// WrappingToken is the one secret any phase returns. It is single-use and
// short-lived, and the script that reads it prints it once and keeps it out of
// every log.
type TokenResult struct {
	Region        string `json:"region"`
	WrappingToken string `json:"wrapping_token"`
	Accessor      string `json:"accessor"`
	WrapTTL       string `json:"wrap_ttl"`
	Period        string `json:"period"`
	NodeCIDR      string `json:"node_cidr"`
	// UnsealAddress is where the node unwraps, which is also where it unseals.
	UnsealAddress string `json:"unseal_address"`
}
