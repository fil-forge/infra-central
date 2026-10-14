package main

import (
	"context"
	"fmt"
	"log/slog"

	"github.com/fil-forge/infra-central/internal/secretstore"
)

// keySpec names one key that lives in Secrets Manager, and the public record
// in SSM that a copy of it must agree with.
type keySpec struct {
	service string
	name    string

	// publicName is the SSM String holding the key's public half, such as
	// identity.did or payer-key.address.
	publicName string
	// derive computes that public half from the private value.
	derive func(value string) (string, error)

	// legacyNames are the SSM SecureStrings this key replaces, the key itself
	// first. Every one of them is deleted once the key is safely in Secrets
	// Manager.
	legacyNames []string
}

// legacyStore is the part of ssmstore.Store the move out of SSM needs.
type legacyStore interface {
	LookupSecret(ctx context.Context, service, name string) (string, bool, error)
	LookupPublic(ctx context.Context, service, name string) (string, bool, error)
	Delete(ctx context.Context, service string, names ...string) ([]string, error)
}

// keyStore is the part of secretstore.Store the move out of SSM needs.
type keyStore interface {
	Lookup(ctx context.Context, service, name string) (secretstore.Secret, bool, error)
	Create(ctx context.Context, service, name, value string) (secretstore.Secret, bool, error)
}

// ensureKey returns the key held in Secrets Manager, minting it only when it
// exists nowhere, and reports whether this call minted it and whether SSM still
// holds copies to delete.
//
// Stages seeded before the keys moved still hold them as SSM SecureStrings.
// Such a key is copied into Secrets Manager and checked against its public
// record. A copied key is not reported as minted: its DID or address is
// unchanged, and so are the proofs it signed.
//
// The SSM copies are left in place. Until the apps root applies, ECS still reads
// them, and the apps apply runs only if the platform apply succeeds, so the
// caller deletes them with deleteMovedKeys once the rest of the seed phase has
// succeeded.
//
// The key's value never reaches a log line or an error message.
func ensureKey(ctx context.Context, keys keyStore, legacy legacyStore, spec keySpec, generate func() (string, error)) (secret secretstore.Secret, created, moved bool, err error) {
	secretName := spec.service + "/" + spec.name

	secret, found, err := keys.Lookup(ctx, spec.service, spec.name)
	if err != nil {
		return secretstore.Secret{}, false, false, err
	}
	legacyValue, legacyFound, err := legacy.LookupSecret(ctx, spec.service, spec.legacyNames[0])
	if err != nil {
		return secretstore.Secret{}, false, false, err
	}

	switch {
	case found && legacyFound:
		// An earlier run copied the key and stopped before deleting the
		// parameter. Deleting is safe only if the two still agree.
		if secret.Value != legacyValue {
			return secretstore.Secret{}, false, false, fmt.Errorf(
				"%s differs between Secrets Manager and SSM; refusing to delete either, resolve it by hand", secretName)
		}
		return secret, false, true, nil

	case found:
		return secret, false, false, nil

	case legacyFound:
		if err := checkPublicRecord(ctx, legacy, spec, legacyValue); err != nil {
			return secretstore.Secret{}, false, false, err
		}
		slog.Info("copying key from SSM to Secrets Manager", "key", secretName)
		secret, _, err = keys.Create(ctx, spec.service, spec.name, legacyValue)
		if err != nil {
			return secretstore.Secret{}, false, false, err
		}
		if secret.Value != legacyValue {
			return secretstore.Secret{}, false, false, fmt.Errorf(
				"%s was created concurrently with a different value; refusing to delete the SSM copy", secretName)
		}
		return secret, false, true, nil

	default:
		value, err := generate()
		if err != nil {
			return secretstore.Secret{}, false, false, fmt.Errorf("generate %s: %w", secretName, err)
		}
		secret, created, err := keys.Create(ctx, spec.service, spec.name, value)
		return secret, created, false, err
	}
}

// deleteMovedKeys deletes the SSM copies of keys ensureKey moved to Secrets
// Manager. A failure part-way leaves the rest in place, and the next seed run
// finds them beside their secrets and deletes them then.
func deleteMovedKeys(ctx context.Context, legacy legacyStore, moved []keySpec) error {
	for _, spec := range moved {
		slog.Info("deleting key parameters moved to Secrets Manager", "key", spec.service+"/"+spec.name)
		if _, err := legacy.Delete(ctx, spec.service, spec.legacyNames...); err != nil {
			return err
		}
	}
	return nil
}

// checkPublicRecord refuses a copy whose DID or address differs from the one
// SSM has published, or that has no published record to compare with.
func checkPublicRecord(ctx context.Context, legacy legacyStore, spec keySpec, value string) error {
	secretName := spec.service + "/" + spec.name

	recorded, found, err := legacy.LookupPublic(ctx, spec.service, spec.publicName)
	if err != nil {
		return err
	}
	if !found {
		return fmt.Errorf("%s has no %s record to check the copy against; refusing to move it",
			secretName, spec.publicName)
	}

	derived, err := spec.derive(value)
	if err != nil {
		return fmt.Errorf("derive the public half of %s: %w", secretName, err)
	}
	if derived != recorded {
		return fmt.Errorf("%s derives %s, but %s records %s; refusing to move it",
			secretName, derived, spec.publicName, recorded)
	}
	return nil
}
