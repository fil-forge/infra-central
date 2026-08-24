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

// openBaoUnsealBudget bounds the wait for the KMS seal to open a barrier this
// invocation just created. The task is already serving by then, so this covers
// one KMS round trip rather than a cold start.
const openBaoUnsealBudget = 1 * time.Minute

// vault configures a running OpenBao: initialise if needed, mount what Forge
// uses, give hilt an AppRole scoped to its own subtree, and reconcile the
// appliance transit keys against the stage's committed region lists.
func (d *deps) vault(ctx context.Context, req Request) (*Response, error) {
	if d.cfg.OpenBaoAddr == "" {
		return nil, fmt.Errorf("FORGE_OPENBAO_ADDR is required for the vault phase")
	}
	// Refuse to run without CIDR bounds rather than silently create an AppRole
	// whose secret_id authenticates from anywhere.
	if len(d.cfg.PrivateCIDRs) == 0 {
		return nil, fmt.Errorf("FORGE_PRIVATE_CIDRS is required for the vault phase")
	}

	client, err := api.NewClient(&api.Config{Address: d.cfg.OpenBaoAddr})
	if err != nil {
		return nil, fmt.Errorf("build openbao client: %w", err)
	}

	slog.Info("waiting for openbao to serve",
		"addr", d.cfg.OpenBaoAddr, "budget", openBaoStartupBudget.String())

	waitCtx, cancel := context.WithTimeout(ctx, openBaoStartupBudget)
	defer cancel()
	if err := vaultinit.WaitForUnsealed(waitCtx, client); err != nil {
		return nil, err
	}

	resp := &Response{Phase: "vault", Created: []string{}}

	slog.Info("resolving the root token")
	rootToken, err := d.ensureRootToken(ctx, client, resp)
	if err != nil {
		return nil, err
	}
	client.SetToken(rootToken)

	// sys/init returns once the barrier is written, and the KMS seal opens it a
	// moment later. Everything below needs an unsealed core, so the wait that
	// an uninitialised server was allowed to skip is owed here instead.
	if resp.Initialised {
		slog.Info("waiting for the new barrier to unseal", "budget", openBaoUnsealBudget.String())

		unsealCtx, cancel := context.WithTimeout(ctx, openBaoUnsealBudget)
		defer cancel()
		if err := vaultinit.WaitForUnsealed(unsealCtx, client); err != nil {
			return nil, err
		}
	}

	slog.Info("ensuring mounts", "hilt_mount", vaultinit.HiltMount, "transit_mount", vaultinit.TransitMount)
	if err := vaultinit.EnsureMounts(ctx, client); err != nil {
		return nil, err
	}

	slog.Info("ensuring hilt approle")
	roleID, err := vaultinit.EnsureHiltAppRole(ctx, client, vaultinit.Config{
		TokenBoundCIDRs: d.cfg.PrivateCIDRs,
	})
	if err != nil {
		return nil, err
	}

	slog.Info("storing hilt approle credentials")
	if err := d.store.PutSecret(ctx, "hilt", "vault-role-id", roleID); err != nil {
		return nil, err
	}
	if err := d.ensureHiltSecretID(ctx, client, resp); err != nil {
		return nil, err
	}

	if err := d.reconcileApplianceKeys(ctx, client, req, resp); err != nil {
		return nil, err
	}

	slog.Info("vault phase complete",
		"initialised", resp.Initialised,
		"hilt_mount", vaultinit.HiltMount,
		"appliance_keys", len(resp.ApplianceKeys))
	return resp, nil
}

// reconcileApplianceKeys brings the appliance transit keys in line with the two
// committed region lists.
//
// Both directions are automated so the committed lists and OpenBao cannot drift
// apart, and the check that makes that safe is in vaultinit.PlanApplianceKeys: a
// key belonging to neither list fails the phase, because the alternative is a
// mistyped region label destroying an unrecreatable key on an apply nobody
// confirmed.
func (d *deps) reconcileApplianceKeys(ctx context.Context, client *api.Client, req Request, resp *Response) error {
	existing, err := vaultinit.ApplianceRegions(ctx, client)
	if err != nil {
		return err
	}

	plan, err := vaultinit.PlanApplianceKeys(existing, req.ApplianceRegions, req.RetiredApplianceRegions)
	if err != nil {
		return err
	}

	slog.Info("reconciling appliance transit keys",
		"live", plan.Active, "retiring", plan.Remove)

	created, err := vaultinit.EnsureApplianceTransitKeys(ctx, client, plan.Active)
	if err != nil {
		return err
	}
	for _, name := range created {
		resp.Created = append(resp.Created, "openbao:transit/keys/"+name)
	}

	for _, region := range plan.Remove {
		if err := d.retireAppliance(ctx, client, region); err != nil {
			return err
		}
		resp.RetiredAppliances = append(resp.RetiredAppliances, region)
	}

	for _, region := range plan.Active {
		resp.ApplianceKeys = append(resp.ApplianceKeys, vaultinit.ApplianceKeyName(region))
	}
	return nil
}

// retireAppliance revokes a retired region's unseal token, removes the
// parameters describing it and destroys its transit key.
//
// Both ends of the order carry weight. Revoking first means the node loses its
// unseal ability even if a later step fails, so a half-finished retirement still
// contains the node it was meant to contain. Destroying the key last makes the
// key the record of whether this finished: anything that fails in between leaves
// it standing, so the next apply still sees the region and runs the whole
// sequence again. Deleting it earlier would strand whatever came after, with
// nothing left to notice.
func (d *deps) retireAppliance(ctx context.Context, client *api.Client, region string) error {
	slog.Warn("retiring an appliance region; its node can never unseal again", "region", region)

	service := applianceService(region)
	accessor, found, err := d.store.LookupPublic(ctx, service, unsealTokenAccessorKey)
	if err != nil {
		return err
	}
	if found {
		if err := vaultinit.RevokeTokenByAccessor(ctx, client, accessor); err != nil {
			return err
		}
	}

	// The role goes too, so nothing can mint a fresh token for a region that no
	// longer has a key to grant access to.
	if err := vaultinit.RemoveApplianceTokenRole(ctx, client, region); err != nil {
		return err
	}

	deleted, err := d.store.DeletePrefix(ctx, service)
	if err != nil {
		return err
	}

	if err := vaultinit.RemoveApplianceTransitKey(ctx, client, region); err != nil {
		return err
	}

	slog.Info("retired appliance region", "region", region, "parameters_deleted", len(deleted))
	return nil
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
		slog.Info("openbao was already initialised; reading the stored root token")
		token, err := d.store.GetSecret(ctx, "openbao", "root-token")
		if err != nil {
			return "", fmt.Errorf("openbao is initialised but its root token is not in SSM: %w", err)
		}
		return token, nil
	}
	slog.Info("openbao was uninitialised; storing the new root token and recovery keys")

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
