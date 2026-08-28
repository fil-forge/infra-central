package main

import (
	"context"
	"encoding/base64"
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

	piriProof, err := decodePiriProof(req)
	if err != nil {
		return nil, err
	}

	ingotDID, err := d.ingotDID()
	if err != nil {
		return nil, err
	}

	onboardReq := onboard.Request{
		Region:            req.Region,
		PiriDID:           req.PiriDID,
		IngotDID:          ingotDID,
		PiriURL:           req.PiriURL,
		PiriProof:         piriProof,
		Weight:            intOrDefault(req.Weight, defaultWeight),
		ReplicationWeight: intOrDefault(req.ReplicationWeight, defaultReplicationWeight),
	}

	if err := d.requireProvisionedRegion(ctx, req.Region); err != nil {
		return nil, err
	}

	onboardDeps, err := d.onboardDeps(ctx, awsCfg.Region, dynamodb.NewFromConfig(awsCfg))
	if err != nil {
		return nil, err
	}

	slog.Info("reading what sprue, hilt and the delegator hold",
		"region", req.Region, "piri", req.PiriDID, "ingot", ingotDID)
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

// decodePiriProof returns the appliance's proof bytes from whichever of the two
// request fields carries it.
//
// Both forms are accepted because a textual container is something a person can
// paste into a direct invocation, while the script cannot tell text from binary
// and encodes either. Refusing both at once rather than preferring one keeps a
// caller from sending two proofs and silently having one ignored.
func decodePiriProof(req Request) ([]byte, error) {
	switch {
	case req.PiriProof != "" && req.PiriProofB64 != "":
		return nil, fmt.Errorf("send the appliance's proof as piri_proof or piri_proof_b64, not both")
	case req.PiriProofB64 != "":
		proof, err := base64.StdEncoding.DecodeString(req.PiriProofB64)
		if err != nil {
			return nil, fmt.Errorf("decode piri_proof_b64: %w", err)
		}
		return proof, nil
	default:
		return []byte(req.PiriProof), nil
	}
}

// requireProvisionedRegion refuses a region label this stage has never issued an
// unseal token for.
//
// A mistyped --region is otherwise accepted, and hilt registers the Ingot under
// the typo permanently: it has no command to move a provider, so the row has to
// be corrected in its database by hand. The recorded token accessor is the
// evidence that the label is real, because an appliance cannot hold the DIDs
// this phase is given without having unsealed with a token minted for exactly
// that label.
func (d *deps) requireProvisionedRegion(ctx context.Context, region string) error {
	_, found, err := d.store.LookupPublic(ctx, applianceService(region), unsealTokenAccessorKey)
	if err != nil {
		return err
	}
	if !found {
		return fmt.Errorf(
			"no unseal token was ever minted for region %q, so either the label is a typo or the appliance is not provisioned; check the region against the stage's appliance_regions and run scripts/mint-appliance-token.sh first",
			region)
	}
	return nil
}

func validateOnboardRequest(req Request) error {
	// An Ingot DID in the request is a caller working from the old contract,
	// where the appliance sent one. Refusing is what stops a stale script from
	// onboarding a different appliance than the one it names.
	if req.IngotDID != "" {
		return fmt.Errorf("ingot_did is no longer an input: an appliance's Ingot did:web is derived from the stage's hostname suffix")
	}

	var missing []string
	for name, value := range map[string]string{
		"region":   req.Region,
		"piri_did": req.PiriDID,
		"piri_url": req.PiriURL,
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

// ingotDID builds an appliance's Ingot identity from the stage's hostname
// suffix, the same shape serviceIssuer builds for hilt and sprue.
//
// Ingot is a did:web on a domain Forge owns, so central derives the DID rather
// than being told it. That removes the input an operator could mistype and makes
// the identity survive a key rotation on the appliance: the node publishes its
// current key in its own DID document, and nothing here changes.
//
// The name is per stage rather than per region, so a stage holds one appliance.
// A second one would collide on this DID and on hilt's region column, which is
// UNIQUE. It is an interim name until the S3 endpoint naming under
// filonecontent.com is settled. See docs/decisions/2026-08-region-onboarding.md.
func (d *deps) ingotDID() (string, error) {
	return fmt.Sprintf("did:web:ingot.%s", d.cfg.HostnameSuffix), nil
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

// proofIssuerKey names the parameter recording which hilt key signed a stored
// appliance proof. It sits beside the proof, under the appliance's own prefix.
const proofIssuerKey = ".issuer"

// applianceProofIssuer returns a function that signs hilt's delegation to an
// appliance's Ingot, once, and reads it back on every run afterwards.
//
// Written once because a delegation is not reproducible: ucantone mints a random
// nonce per delegation, so re-issuing one produces different bytes and a
// different CID, and an appliance holding the previous copy would be holding
// something central no longer recognises as the one it issued.
//
// The exception is a rotated hilt identity, which makes every delegation the old
// key signed unverifiable: hilt's did:web document then publishes only the new
// key. The signing key's did:key is recorded beside the proof so a later run can
// see the rotation and reissue, the same dependency the seed phase tracks for
// the startup proofs.
func (d *deps) applianceProofIssuer(hiltDIDWeb string) func(context.Context, string, string) (string, error) {
	return func(ctx context.Context, region, ingotDID string) (string, error) {
		proof := keygen.HiltIngotS3Proof(applianceService(region), hiltDIDWeb, ingotDID)

		hiltPEM, err := d.store.GetSecret(ctx, "hilt", "identity")
		if err != nil {
			return "", fmt.Errorf("read hilt's identity to sign the proof: %w", err)
		}
		hiltIdentity, err := keygen.ParseIdentity([]byte(hiltPEM))
		if err != nil {
			return "", fmt.Errorf("derive hilt's key DID: %w", err)
		}

		stored, created, err := d.store.EnsurePublic(ctx, proof.Consumer, proof.Name, func() (string, error) {
			return keygen.IssueProof([]byte(hiltPEM), proof)
		})
		if err != nil {
			return "", err
		}

		if created {
			slog.Info("issued hilt's S3 delegation to the appliance",
				"region", region, "audience", ingotDID)
			return stored, d.recordProofIssuer(ctx, proof, hiltIdentity.DID)
		}

		issuer, found, err := d.store.LookupPublic(ctx, proof.Consumer, proof.Name+proofIssuerKey)
		if err != nil {
			return "", err
		}
		if found && issuer == hiltIdentity.DID {
			slog.Info("returning the delegation issued earlier", "region", region)
			return stored, nil
		}
		if !found {
			// A proof stored before this record existed. Its issuer is unknown,
			// and hilt's key is far more likely to be the original than a
			// rotated one, so the record is stamped rather than the proof
			// reissued: reissuing churns the bytes an appliance already holds.
			slog.Info("recording which key signed the stored delegation", "region", region)
			return stored, d.recordProofIssuer(ctx, proof, hiltIdentity.DID)
		}

		slog.Warn("hilt's identity was rotated, reissuing the appliance's delegation",
			"region", region, "was", issuer, "now", hiltIdentity.DID)
		reissued, err := keygen.IssueProof([]byte(hiltPEM), proof)
		if err != nil {
			return "", err
		}
		if err := d.store.PutPublic(ctx, proof.Consumer, proof.Name, reissued); err != nil {
			return "", err
		}
		return reissued, d.recordProofIssuer(ctx, proof, hiltIdentity.DID)
	}
}

// recordProofIssuer stamps a stored proof with the did:key that signed it.
func (d *deps) recordProofIssuer(ctx context.Context, proof keygen.Proof, issuerDID string) error {
	return d.store.PutPublic(ctx, proof.Consumer, proof.Name+proofIssuerKey, issuerDID)
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
