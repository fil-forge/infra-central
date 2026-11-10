package main

import (
	"context"
	"fmt"
	"log/slog"

	"github.com/openbao/openbao/api/v2"

	"github.com/fil-forge/infra-central/internal/vaultinit"
)

// applianceRootStore keeps a second copy of an appliance OpenBao's root token
// and recovery key in central's OpenBao. The first copy is in 1Password.
//
// The request carries both values, so Terraform must never invoke this phase:
// an aws_lambda_invocation would write its input into state. The caller is an
// operator running scripts/store-appliance-root-credentials.sh.
//
// There is no phase that reads them back. Reading is break-glass with central's
// root token, and OpenBao's audit log records it. See
// docs/appliance-onboarding.md.
func (d *deps) applianceRootStore(ctx context.Context, req Request) (*Response, error) {
	if req.Region == "" {
		return nil, fmt.Errorf("a region is required")
	}
	if d.cfg.OpenBaoAddr == "" {
		return nil, fmt.Errorf("FORGE_OPENBAO_ADDR is required for the appliance-root-store phase")
	}

	client, err := d.openBaoAsRoot(ctx)
	if err != nil {
		return nil, err
	}

	plan, err := planRootCredentials(ctx, client, req.Region)
	if err != nil {
		return nil, err
	}
	if !req.Confirm {
		slog.Info("root credentials plan prepared", "region", req.Region, "action", plan.Action)
		return &Response{Phase: "appliance-root-store", DryRun: true, RootCredentialsPlan: plan}, nil
	}

	result, err := storeRootCredentials(ctx, client, req)
	if err != nil {
		return nil, err
	}
	return &Response{Phase: "appliance-root-store", RootCredentialsResult: result}, nil
}

// Root credentials plan actions, which are also what the script prints.
const (
	rootCredentialsActionStore   = "store"
	rootCredentialsActionReplace = "replace"
)

// RootCredentialsPlan is what the dry run reports.
type RootCredentialsPlan struct {
	Region string `json:"region"`
	// Action is store or replace.
	Action string `json:"action"`
	// StoredVersion is the version of the copy already at central, 0 for none.
	StoredVersion int `json:"stored_version"`
}

// RootCredentialsResult reports the version a store wrote. Never the values.
type RootCredentialsResult struct {
	Region  string `json:"region"`
	Version int    `json:"version"`
}

// planRootCredentials reads what a store would change. It needs neither value,
// so the script shows the plan before it asks the operator for them.
func planRootCredentials(ctx context.Context, client *api.Client, region string) (*RootCredentialsPlan, error) {
	if _, err := requireApplianceKey(ctx, client, region); err != nil {
		return nil, err
	}

	version, err := vaultinit.ApplianceRootCredentialsVersion(ctx, client, region)
	if err != nil {
		return nil, err
	}

	plan := &RootCredentialsPlan{Region: region, Action: rootCredentialsActionStore, StoredVersion: version}
	if version > 0 {
		plan.Action = rootCredentialsActionReplace
	}
	return plan, nil
}

// storeRootCredentials writes both values as one version.
//
// Both are required every time. A regenerated root token arrives with the
// recovery key that authorised it, and a version holding only one of them would
// read back as a region with half its credentials lost.
func storeRootCredentials(ctx context.Context, client *api.Client, req Request) (*RootCredentialsResult, error) {
	if req.RootToken == "" || req.RecoveryKey == "" {
		return nil, fmt.Errorf("both the root token and the recovery key are required")
	}

	slog.Info("storing the appliance's root credentials", "region", req.Region)
	version, err := vaultinit.StoreApplianceRootCredentials(ctx, client, req.Region, vaultinit.ApplianceRootCredentials{
		RootToken:   req.RootToken,
		RecoveryKey: req.RecoveryKey,
	})
	if err != nil {
		return nil, err
	}

	// The version is logged and the values are not.
	slog.Info("stored the appliance's root credentials", "region", req.Region, "version", version)
	return &RootCredentialsResult{Region: req.Region, Version: version}, nil
}
