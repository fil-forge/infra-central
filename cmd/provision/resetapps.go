package main

import (
	"context"
	"fmt"
	"log/slog"
	"slices"

	"github.com/jackc/pgx/v5"
	"github.com/openbao/openbao/api/v2"

	"github.com/fil-forge/infra-central/internal/dbinit"
	"github.com/fil-forge/infra-central/internal/vaultinit"
)

// resetAppsPhase wipes the state central's apps keep inside the VPC, so a stage
// can start over without rebuilding its platform.
//
// It drops and recreates the databases of sprue, hilt, swarf and plc, and
// destroys the tenant secrets hilt keeps in OpenBao. Everything else stays: the
// RDS instance, every role and its password, OpenBao with its transit keys and
// hilt's AppRole, and every identity and wallet. The recreated databases are
// empty, and each service migrates its schema when it next starts.
//
// The delegator's tables, sprue's buckets and the region's Piri records live
// outside the VPC. scripts/reset-apps.sh empties those itself, while the
// services are scaled to zero around this phase. See docs/reset-apps.md.
func (d *deps) resetAppsPhase(ctx context.Context, req Request) (*Response, error) {
	if err := checkResettableStage(d.cfg.Stage); err != nil {
		return nil, err
	}
	if d.cfg.OpenBaoAddr == "" {
		return nil, fmt.Errorf("FORGE_OPENBAO_ADDR is required for the reset-apps phase")
	}

	conn, err := d.connectAsMaster(ctx, d.cfg.centralDB())
	if err != nil {
		return nil, err
	}
	defer func() { _ = conn.Close(ctx) }()

	bao, err := d.openBaoAsRoot(ctx)
	if err != nil {
		return nil, err
	}

	plan, err := planResetApps(ctx, conn, bao, d.cfg.Stage)
	if err != nil {
		return nil, err
	}

	if !req.Confirm {
		slog.Info("reset-apps plan prepared",
			"databases", plan.Databases, "hilt_secrets", plan.HiltSecrets)
		return &Response{Phase: "reset-apps", DryRun: true, ResetAppsPlan: plan}, nil
	}

	slog.Warn("resetting the apps' databases and hilt's tenant secrets",
		"stage", d.cfg.Stage, "databases", plan.Databases, "hilt_secrets", plan.HiltSecrets)
	result, err := d.applyResetApps(ctx, conn, bao)
	if err != nil {
		return nil, err
	}
	return &Response{Phase: "reset-apps", ResetAppsResult: result}, nil
}

// appDatabases are the databases this phase drops: every one in
// databaseConsumers except openbao's, which holds the platform's own state.
var appDatabases = []string{
	"sprue",
	"hilt",
	"swarf",
	"plc",
}

// resettableStages are the stages whose app state is disposable.
var resettableStages = []string{"dev", "staging"}

// checkResettableStage refuses every stage but dev and staging. The guard
// lives in the phase rather than only in the script, because the Lambda can be
// invoked without the script.
func checkResettableStage(stage string) error {
	if !slices.Contains(resettableStages, stage) {
		return fmt.Errorf("refusing to reset the apps of stage %q; only %v can be reset", stage, resettableStages)
	}
	return nil
}

// ResetAppsPlan is what a confirmed run would wipe.
type ResetAppsPlan struct {
	Stage string `json:"stage"`
	// Databases are the app databases that exist and would be dropped and
	// recreated empty.
	Databases []string `json:"databases"`
	// HiltSecrets counts the secrets under hilt's tenant subtree in OpenBao.
	HiltSecrets int `json:"hilt_secrets"`
}

// ResetAppsResult is what a confirmed run wiped.
type ResetAppsResult struct {
	Stage string `json:"stage"`
	// Dropped are the databases that existed and were dropped.
	Dropped []string `json:"dropped"`
	// Recreated are the databases now present and empty.
	Recreated []string `json:"recreated"`
	// HiltSecretsDestroyed counts the secrets destroyed in OpenBao.
	HiltSecretsDestroyed int `json:"hilt_secrets_destroyed"`
}

func planResetApps(ctx context.Context, conn *pgx.Conn, bao *api.Client, stage string) (*ResetAppsPlan, error) {
	existing, err := dbinit.Existing(ctx, conn, appDatabases)
	if err != nil {
		return nil, err
	}
	secrets, err := vaultinit.ListHiltSecrets(ctx, bao)
	if err != nil {
		return nil, err
	}
	// An empty list rather than null, so the script can iterate it with jq.
	if existing == nil {
		existing = []string{}
	}
	return &ResetAppsPlan{Stage: stage, Databases: existing, HiltSecrets: len(secrets)}, nil
}

// applyResetApps drops and recreates each database in turn, then destroys
// hilt's secrets.
//
// Each database is recreated straight after its drop, so a run that fails
// partway leaves at most one database missing. Re-running the phase finishes
// the job: a missing database is skipped by the drop and created by Ensure.
//
// The databases go first because hilt's rows are what reference its secrets.
// Destroying the secrets first would leave, on a failed run, a hilt database
// pointing at keys that no longer exist.
func (d *deps) applyResetApps(ctx context.Context, conn *pgx.Conn, bao *api.Client) (*ResetAppsResult, error) {
	result := &ResetAppsResult{Stage: d.cfg.Stage, Dropped: []string{}, Recreated: []string{}}

	for _, name := range appDatabases {
		// The password was stored by the seed phase. Reading it rather than
		// minting one keeps the stored DSN valid; a missing one means seed never
		// ran here, which is not a state this phase should paper over.
		password, err := d.store.GetSecret(ctx, name, "postgres-password")
		if err != nil {
			return nil, fmt.Errorf("read the postgres password for %s: %w", name, err)
		}

		slog.Info("dropping database", "database", name)
		dropped, err := dbinit.Drop(ctx, conn, name)
		if err != nil {
			return nil, err
		}
		if dropped {
			result.Dropped = append(result.Dropped, name)
		}

		slog.Info("recreating database", "database", name)
		if err := dbinit.Ensure(ctx, conn, []dbinit.Database{{Name: name, Password: password}}); err != nil {
			return nil, err
		}
		result.Recreated = append(result.Recreated, name)
	}

	slog.Info("listing hilt's secrets", "mount", vaultinit.HiltMount)
	secrets, err := vaultinit.ListHiltSecrets(ctx, bao)
	if err != nil {
		return nil, err
	}
	slog.Info("destroying hilt's secrets", "count", len(secrets))
	for _, path := range secrets {
		if err := vaultinit.DestroyHiltSecret(ctx, bao, path); err != nil {
			return nil, err
		}
		result.HiltSecretsDestroyed++
	}

	slog.Info("reset-apps complete",
		"dropped", result.Dropped, "recreated", result.Recreated,
		"hilt_secrets_destroyed", result.HiltSecretsDestroyed,
		"next", "scripts/reset-apps.sh scales the services back up")
	return result, nil
}

// openBaoAsRoot returns a client for central's OpenBao holding the break-glass
// root token. hilt's AppRole could destroy its own secrets, but its secret_id is
// bound to hilt's CIDRs and this phase is not hilt.
func (d *deps) openBaoAsRoot(ctx context.Context) (*api.Client, error) {
	client, err := api.NewClient(&api.Config{Address: d.cfg.OpenBaoAddr})
	if err != nil {
		return nil, fmt.Errorf("build openbao client: %w", err)
	}

	slog.Info("waiting for openbao to serve", "addr", d.cfg.OpenBaoAddr)
	waitCtx, cancel := context.WithTimeout(ctx, openBaoUnsealBudget)
	defer cancel()
	if err := vaultinit.WaitForUnsealed(waitCtx, client); err != nil {
		return nil, err
	}

	token, err := d.store.GetSecret(ctx, "openbao", "root-token")
	if err != nil {
		return nil, fmt.Errorf("read openbao's root token: %w", err)
	}
	client.SetToken(token)
	return client, nil
}
