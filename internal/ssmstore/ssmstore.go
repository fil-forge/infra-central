// Package ssmstore holds every secret this project generates, replacing the
// 1Password item that smelt's staging keygen writes to.
//
// Two rules govern everything here.
//
// Nothing is ever regenerated. Writes use Overwrite=false, so an existing
// parameter wins and the caller reads it back instead. This is what makes
// `terraform apply` safe to re-run: a regenerated key would abandon a funded
// wallet and change a DID that other services have already registered.
//
// Private and public material are separate parameters. Private values are
// SecureString under a customer-managed key; public values (DIDs, addresses,
// public keys, UCAN proofs) are plain String. That split means the idempotent
// re-read path never decrypts anything, so the steady-state role does not need
// kms:Decrypt at all.
package ssmstore

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ssm"
	"github.com/aws/aws-sdk-go-v2/service/ssm/types"
)

// Store reads and writes one stage's parameters.
type Store struct {
	client *ssm.Client
	stage  string
	keyID  string // customer-managed KMS key for SecureString values
}

// New returns a Store writing under /forge-central/<stage>/.
func New(client *ssm.Client, stage, kmsKeyID string) *Store {
	return &Store{client: client, stage: stage, keyID: kmsKeyID}
}

// Path renders the fully qualified parameter name for a service and key.
// Every parameter is namespaced by service so a task execution role can be
// scoped to exactly one prefix.
func (s *Store) Path(service, name string) string {
	return fmt.Sprintf("/forge-central/%s/%s/%s", s.stage, service, name)
}

// Prefix renders a service's parameter prefix, which is what IAM policies and
// Terraform outputs refer to.
func (s *Store) Prefix(service string) string {
	return fmt.Sprintf("/forge-central/%s/%s", s.stage, service)
}

// EnsureSecret writes a SecureString only if the parameter does not exist, and
// returns the value now stored along with whether this call created it.
//
// generate is called lazily, so an existing parameter costs no entropy and no
// work. It returns a string rather than taking one because some callers derive
// expensive material (a keypair, a delegation) that should not be built just to
// be discarded.
func (s *Store) EnsureSecret(ctx context.Context, service, name string, generate func() (string, error)) (value string, created bool, err error) {
	return s.ensure(ctx, service, name, types.ParameterTypeSecureString, generate)
}

func (s *Store) ensure(
	ctx context.Context,
	service, name string,
	paramType types.ParameterType,
	generate func() (string, error),
) (value string, created bool, err error) {
	path := s.Path(service, name)

	existing, found, err := s.get(ctx, path, true)
	if err != nil {
		return "", false, err
	}
	if found {
		return existing, false, nil
	}

	value, err = generate()
	if err != nil {
		return "", false, fmt.Errorf("generate %s: %w", path, err)
	}

	if err := s.put(ctx, path, value, paramType, false); err != nil {
		// Another concurrent invocation won the race. Its value is now
		// authoritative; ours is discarded unused.
		if isAlreadyExists(err) {
			existing, _, readErr := s.get(ctx, path, true)
			if readErr != nil {
				return "", false, readErr
			}
			return existing, false, nil
		}
		return "", false, err
	}

	return value, true, nil
}

// PutPublic writes a plaintext String parameter, overwriting freely.
//
// Only for values *derived* from a secret: re-deriving a DID or an address from
// an unchanged key yields the same DID or address, so an overwrite is a no-op
// in practice and a public parameter corrupted out of band heals on the next
// apply. Anything with fresh randomness in it must use EnsurePublic instead.
func (s *Store) PutPublic(ctx context.Context, service, name, value string) error {
	return s.put(ctx, s.Path(service, name), value, types.ParameterTypeString, true)
}

// EnsurePublic writes a plaintext String parameter only if it does not exist.
//
// The case this exists for is UCAN delegations. They are public, but they are
// not reproducible: ucantone mints a random 16-byte nonce per delegation, so
// re-issuing one produces entirely different bytes and a different CID.
// Rewriting on every apply would churn the parameter and invalidate anything
// that had referenced the previous delegation.
func (s *Store) EnsurePublic(ctx context.Context, service, name string, generate func() (string, error)) (value string, created bool, err error) {
	return s.ensure(ctx, service, name, types.ParameterTypeString, generate)
}

// PutSecret writes a SecureString, overwriting any existing value.
//
// Use this only for credentials that their issuer can mint again on demand,
// such as an OpenBao AppRole secret_id. Losing one of those costs a round trip;
// losing a wallet key costs the funds behind it. Anything irreplaceable must go
// through EnsureSecret so that Overwrite=false protects it.
func (s *Store) PutSecret(ctx context.Context, service, name, value string) error {
	path := s.Path(service, name)
	_, err := s.client.PutParameter(ctx, &ssm.PutParameterInput{
		Name:      aws.String(path),
		Value:     aws.String(value),
		Type:      types.ParameterTypeSecureString,
		KeyId:     aws.String(s.keyID),
		Overwrite: aws.Bool(true),
	})
	if err != nil {
		return fmt.Errorf("write %s: %w", path, err)
	}
	return nil
}

// LookupSecret reads a SecureString and reports whether it exists, rather than
// failing when it does not.
func (s *Store) LookupSecret(ctx context.Context, service, name string) (string, bool, error) {
	return s.get(ctx, s.Path(service, name), true)
}

// GetSecret reads a SecureString, decrypting it.
func (s *Store) GetSecret(ctx context.Context, service, name string) (string, error) {
	value, found, err := s.get(ctx, s.Path(service, name), true)
	if err != nil {
		return "", err
	}
	if !found {
		return "", fmt.Errorf("parameter %s not found", s.Path(service, name))
	}
	return value, nil
}

func (s *Store) get(ctx context.Context, path string, decrypt bool) (string, bool, error) {
	out, err := s.client.GetParameter(ctx, &ssm.GetParameterInput{
		Name:           aws.String(path),
		WithDecryption: aws.Bool(decrypt),
	})
	if err != nil {
		var notFound *types.ParameterNotFound
		if errors.As(err, &notFound) {
			return "", false, nil
		}
		return "", false, fmt.Errorf("read %s: %w", path, err)
	}
	return aws.ToString(out.Parameter.Value), true, nil
}

func (s *Store) put(ctx context.Context, path, value string, paramType types.ParameterType, overwrite bool) error {
	in := &ssm.PutParameterInput{
		Name:      aws.String(path),
		Value:     aws.String(value),
		Type:      paramType,
		Overwrite: aws.Bool(overwrite),
	}
	if paramType == types.ParameterTypeSecureString {
		in.KeyId = aws.String(s.keyID)
	}

	if _, err := s.client.PutParameter(ctx, in); err != nil {
		return fmt.Errorf("write %s: %w", path, err)
	}
	return nil
}

func isAlreadyExists(err error) bool {
	var exists *types.ParameterAlreadyExists
	if errors.As(err, &exists) {
		return true
	}
	// The SDK does not always model this as a typed error on PutParameter.
	return strings.Contains(err.Error(), "ParameterAlreadyExists")
}
