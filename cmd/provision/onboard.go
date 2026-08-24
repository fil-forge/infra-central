package main

import (
	"context"
	"fmt"
	"log/slog"

	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	"github.com/fil-forge/ucantone/did"
	"github.com/fil-forge/ucantone/multikey"
	"github.com/fil-forge/ucantone/ucan"
	"github.com/fil-forge/ucantool/pkg/identity"

	"github.com/fil-forge/infra-central/internal/keygen"
	"github.com/fil-forge/infra-central/internal/onboard"
)

// Default provider weights, matching smelt's.
const (
	defaultWeight            = 100
	defaultReplicationWeight = 100
)

// onboardPhase admits a regional appliance to this stage.
//
// Terraform never invokes this phase. The writes it performs are runtime state
// rather than configuration, and their inputs are DIDs that exist only after an
// appliance has provisioned itself, so nothing an apply knows could supply them.
// The caller is an operator running scripts/onboard-appliance.sh.
//
// It signs as sprue and as hilt, because that is what their admin APIs require:
// an invocation is refused unless its issuer is the service's own DID. Those keys
// live in SSM and are readable only by this function, which is the reason the
// writes happen here rather than on an operator's machine.
func (d *deps) onboardPhase(ctx context.Context, req Request) (*Response, error) {
	if err := validateOnboardRequest(req); err != nil {
		return nil, err
	}

	awsCfg, err := awsconfig.LoadDefaultConfig(ctx)
	if err != nil {
		return nil, fmt.Errorf("load AWS config: %w", err)
	}

	onboardReq := onboard.Request{
		Region:            req.Region,
		PiriDID:           req.PiriDID,
		IngotDID:          req.IngotDID,
		PiriURL:           req.PiriURL,
		PiriProof:         []byte(req.PiriProof),
		Weight:            intOrDefault(req.Weight, defaultWeight),
		ReplicationWeight: intOrDefault(req.ReplicationWeight, defaultReplicationWeight),
	}

	onboardDeps, err := d.onboardDeps(ctx, awsCfg.Region, dynamodb.NewFromConfig(awsCfg))
	if err != nil {
		return nil, err
	}

	slog.Info("reading what sprue, hilt and the delegator hold",
		"region", req.Region, "piri", req.PiriDID, "ingot", req.IngotDID)
	state, err := onboard.Read(ctx, onboardDeps, onboardReq)
	if err != nil {
		return nil, err
	}

	plan := onboard.PlanFrom(state, onboardReq)

	if !req.Confirm {
		slog.Info("onboarding plan prepared",
			"actions", len(plan.Actions), "blockers", len(plan.Blockers))
		return &Response{Phase: "onboard", DryRun: true, OnboardPlan: plan}, nil
	}

	slog.Info("performing the onboarding writes", "actions", plan.Actions)
	result, err := onboard.Apply(ctx, onboardDeps, onboardReq, plan)
	if err != nil {
		return nil, err
	}

	slog.Info("appliance onboarded", "region", req.Region, "performed", result.Performed)
	return &Response{Phase: "onboard", OnboardResult: result}, nil
}

func validateOnboardRequest(req Request) error {
	var missing []string
	for name, value := range map[string]string{
		"region":    req.Region,
		"piri_did":  req.PiriDID,
		"ingot_did": req.IngotDID,
		"piri_url":  req.PiriURL,
	} {
		if value == "" {
			missing = append(missing, name)
		}
	}
	if len(missing) > 0 {
		return fmt.Errorf("the onboard phase needs %v; all of it comes from the appliance", missing)
	}
	return nil
}

// onboardDeps assembles the three clients and the proof issuer.
func (d *deps) onboardDeps(ctx context.Context, region string, dynamo *dynamodb.Client) (onboard.Deps, error) {
	table := d.cfg.AllowListTable
	if table == "" {
		return onboard.Deps{}, fmt.Errorf("FORGE_ALLOW_LIST_TABLE is required for the onboard phase")
	}

	sprueIssuer, sprueDIDWeb, err := d.serviceIssuer(ctx, "sprue")
	if err != nil {
		return onboard.Deps{}, err
	}
	sprueClient, err := onboard.NewSprueClient(sprueDIDWeb, d.serviceURL("sprue"), sprueIssuer)
	if err != nil {
		return onboard.Deps{}, err
	}

	hiltIssuer, hiltDIDWeb, err := d.serviceIssuer(ctx, "hilt")
	if err != nil {
		return onboard.Deps{}, err
	}
	hiltDSN, err := d.store.GetSecret(ctx, "hilt", "postgres-dsn")
	if err != nil {
		return onboard.Deps{}, fmt.Errorf("read hilt's database DSN: %w", err)
	}
	hiltClient, err := onboard.NewHiltClient(d.serviceURL("hilt"), hiltDSN, hiltIssuer)
	if err != nil {
		return onboard.Deps{}, err
	}

	return onboard.Deps{
		AllowList:  onboard.NewDynamoAllowList(dynamo, table, d.cfg.Stage),
		Sprue:      sprueClient,
		Hilt:       hiltClient,
		IssueProof: d.applianceProofIssuer(hiltDIDWeb),
	}, nil
}

// applianceProofIssuer returns a function that signs hilt's delegation to an
// appliance's Ingot, once, and reads it back on every run afterwards.
//
// Written once because a delegation is not reproducible: ucantone mints a random
// nonce per delegation, so re-issuing one produces different bytes and a
// different CID, and an appliance holding the previous copy would be holding
// something central no longer recognises as the one it issued.
func (d *deps) applianceProofIssuer(hiltDIDWeb string) func(context.Context, string, string) (string, error) {
	return func(ctx context.Context, region, ingotDID string) (string, error) {
		proof := keygen.HiltIngotS3Proof(applianceService(region), hiltDIDWeb, ingotDID)

		stored, created, err := d.store.EnsurePublic(ctx, proof.Consumer, proof.Name, func() (string, error) {
			hiltPEM, err := d.store.GetSecret(ctx, "hilt", "identity")
			if err != nil {
				return "", fmt.Errorf("read hilt's identity to sign the proof: %w", err)
			}
			return keygen.IssueProof([]byte(hiltPEM), proof)
		})
		if err != nil {
			return "", err
		}

		if created {
			slog.Info("issued hilt's S3 delegation to the appliance",
				"region", region, "audience", ingotDID)
		} else {
			slog.Info("returning the delegation issued earlier", "region", region)
		}
		return stored, nil
	}
}

// serviceIssuer builds an issuer that signs with a service's key and presents
// its did:web, which is the identity its admin API checks against.
func (d *deps) serviceIssuer(ctx context.Context, service string) (ucan.Issuer, string, error) {
	pem, err := d.store.GetSecret(ctx, service, "identity")
	if err != nil {
		return nil, "", fmt.Errorf("read %s's identity: %w", service, err)
	}

	signer, err := identity.DecodeSignerFromPEM([]byte(pem))
	if err != nil {
		return nil, "", fmt.Errorf("decode %s's identity: %w", service, err)
	}

	didWeb := fmt.Sprintf("did:web:%s.%s", service, d.cfg.HostnameSuffix)
	parsed, err := did.Parse(didWeb)
	if err != nil {
		return nil, "", fmt.Errorf("parse %s: %w", didWeb, err)
	}

	return multikey.NewIssuer(parsed, signer), didWeb, nil
}

// serviceURL is where a service answers. The Lambda reaches both over the public
// ALB through the NAT gateway, which is the same path hilt already takes to
// resolve sprue's did:web document.
func (d *deps) serviceURL(service string) string {
	return fmt.Sprintf("https://%s.%s", service, d.cfg.HostnameSuffix)
}

func intOrDefault(value, fallback int) int {
	if value == 0 {
		return fallback
	}
	return value
}
