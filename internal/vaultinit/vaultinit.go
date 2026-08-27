// Package vaultinit brings a freshly started OpenBao to a usable state:
// initialised, with the mounts Forge needs and an AppRole for hilt.
//
// It deliberately does more than smelt does. smelt hands hilt the Vault root
// token and records that as debt; here hilt gets an AppRole whose policy
// reaches only its own tenant secrets. The root token is stored once, for
// break-glass use, and is not wired into any service.
//
// Every step checks before it acts, because this runs on every apply.
package vaultinit

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/openbao/openbao/api/v2"
)

const (
	// HiltMount is where hilt's KV v2 engine lives. hilt's own path builder
	// emits tenant/<did> relative to its configured mount, so mounting here
	// puts every hilt secret under forge-central/hilt without a hilt code
	// change. HILT_VAULT_OPENBAO_MOUNT in modules/apps must match.
	HiltMount = "forge-central/hilt"

	// TransitMount backs the regional appliances' seal "transit" auto-unseal,
	// per fil-one/RFC#21.
	TransitMount = "transit"

	// AppliancePrefix names both the transit key and the policy belonging to one
	// appliance. OpenBao mounts cannot nest, so per-node grouping lives in key
	// names rather than sub-paths; the prefix is what makes the set of appliance
	// keys enumerable, which is what the reconciliation below rests on.
	AppliancePrefix = "appliance-unseal-"

	hiltPolicyName   = "hilt"
	hiltAppRoleName  = "hilt"
	appRoleAuthMount = "approle"
)

// ApplianceKeyName returns the transit key and policy name for a region label.
func ApplianceKeyName(region string) string {
	return AppliancePrefix + region
}

// InitResult reports what initialisation produced. Both fields are secret and
// belong in SSM immediately; neither is returned to Terraform.
type InitResult struct {
	RootToken    string
	RecoveryKeys []string
	// Initialised is false when OpenBao was already set up, in which case the
	// two fields above are empty and the caller must use its stored root token.
	Initialised bool
}

// Config carries the knobs a caller may reasonably want to vary.
type Config struct {
	// TokenBoundCIDRs restricts where hilt's AppRole token may be used. On
	// Fargate this is the VPC's private subnets: it separates the VPC from the
	// internet, but not one task from another. Task identity rests on IAM
	// controlling who can read the secret_id from SSM.
	TokenBoundCIDRs []string
}

// WaitForUnsealed blocks until OpenBao is ready to be configured, or the
// context expires. Ready means serving and either unsealed or not yet
// initialised.
//
// The wait exists because Terraform invokes this Lambda as soon as the ECS
// service is created, which is well before the task is serving. With KMS seal
// there is no unseal step to perform, only one to wait for.
//
// Uninitialised counts as ready because it has to. A first bring-up reports
// sealed until something calls sys/init, and the caller is that something, so
// treating sealed as a reason to keep waiting deadlocks the first apply of
// every stage against a server that is behaving correctly.
func WaitForUnsealed(ctx context.Context, client *api.Client) error {
	const interval = 3 * time.Second

	// Every attempt is logged. A task that never starts makes this loop the
	// whole of the phase, and without the reason each poll gave, the only
	// evidence left is a timeout four minutes later that names no cause.
	var lastErr error
	for attempt := 1; ; attempt++ {
		health, err := client.Sys().SealStatusWithContext(ctx)
		switch {
		case err != nil:
			lastErr = err
		case !health.Initialized:
			// An OpenBao that has never been initialised reports itself sealed,
			// because there is no barrier to unseal yet. Waiting for it to stop
			// would wait forever: initialising it is the caller's next step.
			return nil
		case health.Sealed:
			// Initialised and still sealed means the KMS seal did not open it.
			lastErr = fmt.Errorf("openbao is sealed; check that the KMS seal key is reachable from the task role")
		default:
			return nil
		}
		slog.Info("openbao is not ready yet", "attempt", attempt, "reason", lastErr)

		select {
		case <-ctx.Done():
			return fmt.Errorf("waiting for openbao: %w (last status: %v)", ctx.Err(), lastErr)
		case <-time.After(interval):
		}
	}
}

// EnsureInitialised initialises OpenBao if it has not been already.
//
// The shares are recovery shares rather than unseal shares: with seal "awskms"
// the barrier key is wrapped by KMS, and the recovery keys exist only to
// authorise operations such as regenerating a root token.
func EnsureInitialised(ctx context.Context, client *api.Client) (InitResult, error) {
	initialised, err := client.Sys().InitStatusWithContext(ctx)
	if err != nil {
		return InitResult{}, fmt.Errorf("read init status: %w", err)
	}
	if initialised {
		return InitResult{Initialised: false}, nil
	}

	resp, err := client.Sys().InitWithContext(ctx, &api.InitRequest{
		RecoveryShares:    1,
		RecoveryThreshold: 1,
	})
	if err != nil {
		return InitResult{}, fmt.Errorf("initialise openbao: %w", err)
	}

	return InitResult{
		RootToken:    resp.RootToken,
		RecoveryKeys: resp.RecoveryKeysB64,
		Initialised:  true,
	}, nil
}

// EnsureMounts brings up hilt's KV v2 engine and the transit engine. The client
// must carry a root or equivalently privileged token.
//
// No audit device is enabled: OpenBao 2.x rejects audit devices created over
// the API and takes them only from the server config file. See the audit
// follow-up in README.md.
func EnsureMounts(ctx context.Context, client *api.Client) error {
	mounts, err := client.Sys().ListMountsWithContext(ctx)
	if err != nil {
		return fmt.Errorf("list mounts: %w", err)
	}

	if _, ok := mounts[HiltMount+"/"]; !ok {
		err := client.Sys().MountWithContext(ctx, HiltMount, &api.MountInput{
			Type:    "kv",
			Options: map[string]string{"version": "2"},
		})
		if err != nil {
			return fmt.Errorf("mount kv v2 at %s: %w", HiltMount, err)
		}
	}

	if _, ok := mounts[TransitMount+"/"]; !ok {
		if err := client.Sys().MountWithContext(ctx, TransitMount, &api.MountInput{Type: "transit"}); err != nil {
			return fmt.Errorf("mount transit: %w", err)
		}
	}

	return nil
}

// EnsureHiltAppRole writes hilt's policy, enables AppRole auth, creates the
// role, and returns its role_id.
func EnsureHiltAppRole(ctx context.Context, client *api.Client, cfg Config) (roleID string, err error) {
	if err := client.Sys().PutPolicyWithContext(ctx, hiltPolicyName, hiltPolicy()); err != nil {
		return "", fmt.Errorf("write hilt policy: %w", err)
	}

	auths, err := client.Sys().ListAuthWithContext(ctx)
	if err != nil {
		return "", fmt.Errorf("list auth methods: %w", err)
	}
	if _, ok := auths[appRoleAuthMount+"/"]; !ok {
		err := client.Sys().EnableAuthWithOptionsWithContext(ctx, appRoleAuthMount, &api.EnableAuthOptions{Type: "approle"})
		if err != nil {
			return "", fmt.Errorf("enable approle auth: %w", err)
		}
	}

	role := map[string]any{
		"token_policies": []string{hiltPolicyName},
		"token_ttl":      "1h",
		"token_max_ttl":  "24h",
		// hilt re-authenticates as needed, so its secret_id does not expire on
		// its own. Rotation is a deliberate act, not a timer.
		"secret_id_ttl":         "0",
		"secret_id_num_uses":    0,
		"token_bound_cidrs":     cfg.TokenBoundCIDRs,
		"secret_id_bound_cidrs": cfg.TokenBoundCIDRs,
	}
	rolePath := fmt.Sprintf("auth/%s/role/%s", appRoleAuthMount, hiltAppRoleName)
	if _, err := client.Logical().WriteWithContext(ctx, rolePath, role); err != nil {
		return "", fmt.Errorf("write approle role: %w", err)
	}

	resp, err := client.Logical().ReadWithContext(ctx, rolePath+"/role-id")
	if err != nil {
		return "", fmt.Errorf("read role-id: %w", err)
	}
	if resp == nil {
		return "", fmt.Errorf("role-id not found at %s", rolePath)
	}
	roleID, ok := resp.Data["role_id"].(string)
	if !ok {
		return "", fmt.Errorf("role-id response has no role_id field")
	}
	return roleID, nil
}

// SecretIDValid reports whether a stored secret_id still authenticates.
//
// Worth checking because a stored secret_id outlives the OpenBao that issued
// it: rebuild the stage's storage and every previously issued credential is
// gone, while the SSM parameter that holds it survives untouched.
func SecretIDValid(ctx context.Context, client *api.Client, secretID string) bool {
	path := fmt.Sprintf("auth/%s/role/%s/secret-id/lookup", appRoleAuthMount, hiltAppRoleName)
	resp, err := client.Logical().WriteWithContext(ctx, path, map[string]any{"secret_id": secretID})
	return err == nil && resp != nil
}

// IssueSecretID mints a new secret_id for hilt's AppRole.
func IssueSecretID(ctx context.Context, client *api.Client) (string, error) {
	path := fmt.Sprintf("auth/%s/role/%s/secret-id", appRoleAuthMount, hiltAppRoleName)
	resp, err := client.Logical().WriteWithContext(ctx, path, nil)
	if err != nil {
		return "", fmt.Errorf("issue secret-id: %w", err)
	}
	if resp == nil {
		return "", fmt.Errorf("secret-id response was empty")
	}
	secretID, ok := resp.Data["secret_id"].(string)
	if !ok {
		return "", fmt.Errorf("secret-id response has no secret_id field")
	}
	return secretID, nil
}

// hiltPolicy grants hilt exactly the KV v2 subtree it stores tenant material
// in. The delete and destroy paths are separate endpoints in KV v2, so omitting
// them would leave hilt able to write tenants it could never remove.
func hiltPolicy() string {
	return fmt.Sprintf(`
path "%[1]s/data/tenant/*" {
  capabilities = ["create", "read", "update", "patch", "delete", "list"]
}

path "%[1]s/metadata/tenant/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "%[1]s/delete/tenant/*" {
  capabilities = ["update"]
}

path "%[1]s/undelete/tenant/*" {
  capabilities = ["update"]
}

path "%[1]s/destroy/tenant/*" {
  capabilities = ["update"]
}
`, HiltMount)
}
