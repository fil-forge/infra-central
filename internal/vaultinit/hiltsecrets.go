package vaultinit

import (
	"context"
	"fmt"
	"strings"

	"github.com/openbao/openbao/api/v2"
)

// hiltSecretsRoot is the subtree of HiltMount that hilt writes tenant material
// to, and the only one its policy reaches.
const hiltSecretsRoot = "tenant/"

// ListHiltSecrets returns the path of every secret hilt has stored, relative to
// HiltMount.
//
// hilt nests its paths (a tenant's signing key and every access key's signer
// sit under the tenant's DID), so the walk recurses into each folder the list
// endpoint returns.
func ListHiltSecrets(ctx context.Context, client *api.Client) ([]string, error) {
	return listHiltSecrets(ctx, client, hiltSecretsRoot)
}

func listHiltSecrets(ctx context.Context, client *api.Client, folder string) ([]string, error) {
	resp, err := client.Logical().ListWithContext(ctx, HiltMount+"/metadata/"+folder)
	if err != nil {
		return nil, fmt.Errorf("list hilt's secrets under %s: %w", folder, err)
	}
	// A folder with nothing in it is a 404, which the client reports as no
	// response rather than an error.
	if resp == nil || resp.Data == nil {
		return nil, nil
	}

	keys, ok := resp.Data["keys"].([]any)
	if !ok {
		return nil, fmt.Errorf("list hilt's secrets under %s: response has no keys", folder)
	}

	var paths []string
	for _, raw := range keys {
		key, ok := raw.(string)
		if !ok || key == "" {
			return nil, fmt.Errorf("list hilt's secrets under %s: unexpected key %v", folder, raw)
		}
		if strings.HasSuffix(key, "/") {
			nested, err := listHiltSecrets(ctx, client, folder+key)
			if err != nil {
				return nil, err
			}
			paths = append(paths, nested...)
			continue
		}
		paths = append(paths, folder+key)
	}
	return paths, nil
}

// DestroyHiltSecret permanently deletes one of hilt's secrets, every version
// and its metadata. The path is one ListHiltSecrets returned.
//
// The mount, hilt's policy and its AppRole are left alone, so hilt keeps
// writing tenant secrets the moment it is running again.
func DestroyHiltSecret(ctx context.Context, client *api.Client, path string) error {
	if !strings.HasPrefix(path, hiltSecretsRoot) {
		return fmt.Errorf("refusing to destroy %s: hilt's secrets all live under %s", path, hiltSecretsRoot)
	}
	if err := client.KVv2(HiltMount).DeleteMetadata(ctx, path); err != nil {
		return fmt.Errorf("destroy hilt's secret %s: %w", path, err)
	}
	return nil
}
