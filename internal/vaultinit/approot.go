package vaultinit

import (
	"context"
	"errors"
	"fmt"

	"github.com/openbao/openbao/api/v2"
)

// ApplianceRootMount is the KV v2 engine holding the second copy of each
// appliance OpenBao's root token and recovery key, one secret per region label.
// The first copy is in 1Password.
//
// No policy names this mount, so only central's root token reads it. Reading is
// break-glass, and the audit device records it by path.
const ApplianceRootMount = "forge-central/appliance-root"

// ApplianceRootCredentials are what an appliance's OpenBao prints once, at init.
type ApplianceRootCredentials struct {
	RootToken   string
	RecoveryKey string
}

// ApplianceRootCredentialsVersion returns the version of the copy stored for a
// region, or 0 when there is none. It reads metadata only.
func ApplianceRootCredentialsVersion(ctx context.Context, client *api.Client, region string) (int, error) {
	metadata, err := client.KVv2(ApplianceRootMount).GetMetadata(ctx, region)
	if errors.Is(err, api.ErrSecretNotFound) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("read the metadata of %s's root credentials: %w", region, err)
	}
	return metadata.CurrentVersion, nil
}

// StoreApplianceRootCredentials writes a region's root token and recovery key
// as a new version and returns that version.
func StoreApplianceRootCredentials(ctx context.Context, client *api.Client, region string, creds ApplianceRootCredentials) (int, error) {
	secret, err := client.KVv2(ApplianceRootMount).Put(ctx, region, map[string]any{
		"root_token":   creds.RootToken,
		"recovery_key": creds.RecoveryKey,
	})
	if err != nil {
		return 0, fmt.Errorf("store %s's root credentials: %w", region, err)
	}
	return secret.VersionMetadata.Version, nil
}

// RemoveApplianceRootCredentials destroys every version of a region's copy. A
// region that never had one is not an error, so a retirement can run again.
func RemoveApplianceRootCredentials(ctx context.Context, client *api.Client, region string) error {
	if err := client.KVv2(ApplianceRootMount).DeleteMetadata(ctx, region); err != nil {
		return fmt.Errorf("remove %s's root credentials: %w", region, err)
	}
	return nil
}
