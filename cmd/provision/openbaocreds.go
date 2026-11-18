package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"

	"github.com/fil-forge/infra-central/internal/secretstore"
	"github.com/fil-forge/infra-central/internal/vaultinit"
)

// OpenBao's break-glass credentials live in Secrets Manager under the openbao
// service, so the backup replica covers them like the identities and wallets.
// Without a copy outside the stage's region, a restored OpenBao would admit
// nobody, and the recovery keys cannot be regenerated.
const (
	openBaoService       = "openbao"
	openBaoRootTokenName = "root-token"
	openBaoRecoveryName  = "recovery-keys"
)

// openBaoCredentialNames lists both credentials in the order they are stored.
var openBaoCredentialNames = []string{openBaoRootTokenName, openBaoRecoveryName}

// credentialStore is the part of secretstore.Store that storing OpenBao's
// credentials needs.
type credentialStore interface {
	keyStore
	PutIfChanged(ctx context.Context, service, name, value string) (secretstore.Secret, error)
}

// openBaoCredentials is what ensureOpenBaoCredentials leaves behind: the root
// token to configure OpenBao with, the ARN of each stored credential, and
// whether SSM may still hold copies to delete once the vault phase succeeds.
type openBaoCredentials struct {
	rootToken    string
	arns         map[string]string
	deleteLegacy bool
}

// ensureOpenBaoCredentials puts OpenBao's root token and recovery keys in
// Secrets Manager and returns the root token.
//
// When this invocation initialised OpenBao, the new values overwrite whatever
// Secrets Manager holds: secrets survive a stage destroy, and a stored value
// from an OpenBao whose storage was rebuilt no longer opens anything. Any SSM
// copy belongs to that dead OpenBao too, and is marked for deletion.
//
// When OpenBao was already initialised, each credential is moved out of SSM
// on its own, so a run that stopped between the two finishes the move.
//
// No value reaches a log line or an error message.
func ensureOpenBaoCredentials(ctx context.Context, keys credentialStore, legacy legacyStore, init vaultinit.InitResult) (openBaoCredentials, error) {
	creds := openBaoCredentials{arns: map[string]string{}}

	if init.Initialised {
		recovery, err := json.Marshal(init.RecoveryKeys)
		if err != nil {
			return openBaoCredentials{}, fmt.Errorf("encode recovery keys: %w", err)
		}
		values := map[string]string{
			openBaoRootTokenName: init.RootToken,
			openBaoRecoveryName:  string(recovery),
		}
		// Store the credentials before anything else can fail. An initialised
		// OpenBao whose root token was never persisted is unrecoverable.
		for _, name := range openBaoCredentialNames {
			secret, err := keys.PutIfChanged(ctx, openBaoService, name, values[name])
			if err != nil {
				return openBaoCredentials{}, err
			}
			creds.arns[name] = secret.ARN
		}
		creds.rootToken = init.RootToken
		creds.deleteLegacy = true
		return creds, nil
	}

	for _, name := range openBaoCredentialNames {
		secret, moved, err := moveOpenBaoCredential(ctx, keys, legacy, name)
		if err != nil {
			return openBaoCredentials{}, err
		}
		creds.arns[name] = secret.ARN
		creds.deleteLegacy = creds.deleteLegacy || moved
		if name == openBaoRootTokenName {
			creds.rootToken = secret.Value
		}
	}
	return creds, nil
}

// moveOpenBaoCredential returns one credential of an already initialised
// OpenBao from Secrets Manager, copying it there from SSM when a stage still
// holds it only as a SecureString, and reports whether SSM holds a copy to
// delete.
//
// Two copies that disagree, or a credential found in neither store, fail the
// phase and delete nothing: either one means the stored value may not open
// this OpenBao, and only a human can tell which copy does.
func moveOpenBaoCredential(ctx context.Context, keys keyStore, legacy legacyStore, name string) (secretstore.Secret, bool, error) {
	credential := openBaoService + "/" + name

	secret, found, err := keys.Lookup(ctx, openBaoService, name)
	if err != nil {
		return secretstore.Secret{}, false, err
	}
	legacyValue, legacyFound, err := legacy.LookupSecret(ctx, openBaoService, name)
	if err != nil {
		return secretstore.Secret{}, false, err
	}

	switch {
	case found && legacyFound:
		if secret.Value != legacyValue {
			return secretstore.Secret{}, false, fmt.Errorf(
				"%s differs between Secrets Manager and SSM; refusing to delete either, resolve it by hand", credential)
		}
		return secret, true, nil

	case found:
		return secret, false, nil

	case legacyFound:
		slog.Info("copying openbao credential from SSM to Secrets Manager", "credential", credential)
		secret, _, err := keys.Create(ctx, openBaoService, name, legacyValue)
		if err != nil {
			return secretstore.Secret{}, false, err
		}
		if secret.Value != legacyValue {
			return secretstore.Secret{}, false, fmt.Errorf(
				"%s was created concurrently with a different value; refusing to delete the SSM copy", credential)
		}
		return secret, true, nil

	default:
		return secretstore.Secret{}, false, fmt.Errorf(
			"openbao is initialised but %s is in neither Secrets Manager nor SSM; restore it from a backup", credential)
	}
}

// replicateOpenBaoCredentials gives both credentials a replica in the DR
// region and waits until each one is in sync. It reports the region and the
// replicas it added on resp, and keeps the ARNs out of the vault result.
func replicateOpenBaoCredentials(ctx context.Context, keys replicator, region string, arns map[string]string, resp *Response) error {
	scratch := &Response{Secrets: map[string]map[string]string{openBaoService: arns}}
	if err := replicateKeys(ctx, keys, region, scratch); err != nil {
		return err
	}
	resp.BackupReplicaRegion = scratch.BackupReplicaRegion
	resp.Replicated = append(resp.Replicated, scratch.Replicated...)
	return nil
}

// openBaoRootToken reads the root token for the phases that act on OpenBao
// as root. Secrets Manager holds it once the vault phase has run with this
// image; until then a stage still has it only in SSM, so that is read next.
// It writes nothing.
func openBaoRootToken(ctx context.Context, keys keyStore, legacy legacyStore) (string, error) {
	secret, found, err := keys.Lookup(ctx, openBaoService, openBaoRootTokenName)
	if err != nil {
		return "", err
	}
	if found {
		return secret.Value, nil
	}

	token, found, err := legacy.LookupSecret(ctx, openBaoService, openBaoRootTokenName)
	if err != nil {
		return "", err
	}
	if !found {
		return "", fmt.Errorf("openbao's root token is in neither Secrets Manager nor SSM")
	}
	return token, nil
}
