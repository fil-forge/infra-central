package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"time"

	"github.com/openbao/openbao/api/v2"

	"github.com/fil-forge/infra-central/internal/vaultinit"
)

// openBaoStartupBudget bounds the wait for the ECS service to start serving.
// Terraform creates the service and invokes this function immediately, so the
// first apply of a stage always waits out a cold start.
const openBaoStartupBudget = 4 * time.Minute

// vault configures a running OpenBao: initialise if needed, mount what Forge
// uses, and give hilt an AppRole scoped to its own subtree.
func (d *deps) vault(ctx context.Context) (*Response, error) {
	if d.cfg.OpenBaoAddr == "" {
		return nil, fmt.Errorf("FORGE_OPENBAO_ADDR is required for the vault phase")
	}

	client, err := api.NewClient(&api.Config{Address: d.cfg.OpenBaoAddr})
	if err != nil {
		return nil, fmt.Errorf("build openbao client: %w", err)
	}

	waitCtx, cancel := context.WithTimeout(ctx, openBaoStartupBudget)
	defer cancel()
	if err := vaultinit.WaitForUnsealed(waitCtx, client); err != nil {
		return nil, err
	}

	resp := &Response{Phase: "vault", Created: []string{}}

	rootToken, err := d.ensureRootToken(ctx, client, resp)
	if err != nil {
		return nil, err
	}
	client.SetToken(rootToken)

	if err := vaultinit.EnsureMounts(ctx, client); err != nil {
		return nil, err
	}

	roleID, err := vaultinit.EnsureHiltAppRole(ctx, client, vaultinit.Config{
		TokenBoundCIDRs: d.cfg.PrivateCIDRs,
	})
	if err != nil {
		return nil, err
	}
	if err := d.store.PutSecret(ctx, "hilt", "vault-role-id", roleID); err != nil {
		return nil, err
	}
	if err := d.ensureHiltSecretID(ctx, client, resp); err != nil {
		return nil, err
	}

	slog.Info("vault phase complete",
		"initialised", resp.Initialised,
		"hilt_mount", vaultinit.HiltMount)
	return resp, nil
}

// ensureRootToken initialises OpenBao on first run and returns the root token,
// reading the stored one on every subsequent run.
//
// The root token is kept for break-glass use only. No service is given it,
// which is the difference from smelt, where hilt authenticates as root.
func (d *deps) ensureRootToken(ctx context.Context, client *api.Client, resp *Response) (string, error) {
	result, err := vaultinit.EnsureInitialised(ctx, client)
	if err != nil {
		return "", err
	}

	if !result.Initialised {
		token, err := d.store.GetSecret(ctx, "openbao", "root-token")
		if err != nil {
			return "", fmt.Errorf("openbao is initialised but its root token is not in SSM: %w", err)
		}
		return token, nil
	}

	// Store the credentials before anything else can fail. An initialised
	// OpenBao whose root token was never persisted is unrecoverable.
	if err := d.store.PutSecret(ctx, "openbao", "root-token", result.RootToken); err != nil {
		return "", err
	}
	recovery, err := json.Marshal(result.RecoveryKeys)
	if err != nil {
		return "", fmt.Errorf("encode recovery keys: %w", err)
	}
	if err := d.store.PutSecret(ctx, "openbao", "recovery-keys", string(recovery)); err != nil {
		return "", err
	}

	resp.Initialised = true
	resp.Created = append(resp.Created,
		d.store.Path("openbao", "root-token"),
		d.store.Path("openbao", "recovery-keys"))
	return result.RootToken, nil
}

// ensureHiltSecretID keeps hilt's stored secret_id in step with OpenBao.
//
// A stored secret_id can outlive the OpenBao that issued it: the SSM parameter
// survives a storage rebuild that wiped every credential. Validating before
// reusing turns that into a silent self-heal instead of an authentication
// failure at hilt's startup.
func (d *deps) ensureHiltSecretID(ctx context.Context, client *api.Client, resp *Response) error {
	stored, found, err := d.store.LookupSecret(ctx, "hilt", "vault-secret-id")
	if err != nil {
		return err
	}
	if found && vaultinit.SecretIDValid(ctx, client, stored) {
		return nil
	}

	secretID, err := vaultinit.IssueSecretID(ctx, client)
	if err != nil {
		return err
	}
	if err := d.store.PutSecret(ctx, "hilt", "vault-secret-id", secretID); err != nil {
		return err
	}

	resp.Created = append(resp.Created, d.store.Path("hilt", "vault-secret-id"))
	if found {
		slog.Warn("replaced a stale hilt secret_id; the previous one no longer authenticated")
	}
	return nil
}
