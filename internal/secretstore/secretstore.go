// Package secretstore holds the keys this project cannot afford to lose: the
// service identities and the two funded wallets.
//
// It follows the same never-regenerate rule as ssmstore. An existing secret
// always wins, and a caller that loses a creation race reads the winner back.
// Nothing here deletes a secret: rotating a key is an operator's deliberate act
// (see the README), never a side effect of an apply.
//
// The keys live in Secrets Manager rather than SSM so they can be replicated
// to a second region, which SSM cannot do. EnsureReplica adds that replica.
//
// Secrets take the account's AWS-managed aws/secretsmanager key, for the same
// reason ssmstore uses the AWS-managed SSM key. The stage's own key is
// destroyed with the stage, and a key pending deletion stops decrypting at
// once, which would leave the payer key unreadable after a reset. The
// AWS-managed key cannot be deleted.
package secretstore

import (
	"context"
	"errors"
	"fmt"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/secretsmanager"
	"github.com/aws/aws-sdk-go-v2/service/secretsmanager/types"
)

// api is the slice of the Secrets Manager client this package uses, split out
// so tests can substitute a fake.
type api interface {
	GetSecretValue(ctx context.Context, in *secretsmanager.GetSecretValueInput, optFns ...func(*secretsmanager.Options)) (*secretsmanager.GetSecretValueOutput, error)
	CreateSecret(ctx context.Context, in *secretsmanager.CreateSecretInput, optFns ...func(*secretsmanager.Options)) (*secretsmanager.CreateSecretOutput, error)
	PutSecretValue(ctx context.Context, in *secretsmanager.PutSecretValueInput, optFns ...func(*secretsmanager.Options)) (*secretsmanager.PutSecretValueOutput, error)
	DescribeSecret(ctx context.Context, in *secretsmanager.DescribeSecretInput, optFns ...func(*secretsmanager.Options)) (*secretsmanager.DescribeSecretOutput, error)
	ReplicateSecretToRegions(ctx context.Context, in *secretsmanager.ReplicateSecretToRegionsInput, optFns ...func(*secretsmanager.Options)) (*secretsmanager.ReplicateSecretToRegionsOutput, error)
}

// Store reads and writes one stage's secrets in the region its client calls.
type Store struct {
	client api
	stage  string
	region string
}

// New returns a Store writing under forge-central/<stage>/.
func New(client *secretsmanager.Client, stage string) *Store {
	return &Store{client: client, stage: stage, region: client.Options().Region}
}

// Secret is a stored value and the full ARN that names it. ECS needs the full
// ARN: a name alone is read as an SSM parameter.
type Secret struct {
	Value string
	ARN   string
}

// Name renders the secret name for a service and key. It mirrors the SSM
// layout without the leading slash, so a task execution role can be scoped to
// forge-central/<stage>/<service>/*.
func (s *Store) Name(service, name string) string {
	return fmt.Sprintf("forge-central/%s/%s/%s", s.stage, service, name)
}

// Lookup reads a secret and reports whether it exists, rather than failing
// when it does not.
func (s *Store) Lookup(ctx context.Context, service, name string) (Secret, bool, error) {
	return s.get(ctx, s.Name(service, name))
}

// Get reads a secret that must exist.
func (s *Store) Get(ctx context.Context, service, name string) (Secret, error) {
	secret, found, err := s.Lookup(ctx, service, name)
	if err != nil {
		return Secret{}, err
	}
	if !found {
		return Secret{}, fmt.Errorf("secret %s not found", s.Name(service, name))
	}
	return secret, nil
}

// Ensure creates a secret only if it does not exist, and returns the secret
// now stored along with whether this call created it.
//
// generate is called lazily, so an existing secret costs no entropy.
func (s *Store) Ensure(ctx context.Context, service, name string, generate func() (string, error)) (Secret, bool, error) {
	existing, found, err := s.Lookup(ctx, service, name)
	if err != nil {
		return Secret{}, false, err
	}
	if found {
		return existing, false, nil
	}

	value, err := generate()
	if err != nil {
		return Secret{}, false, fmt.Errorf("generate %s: %w", s.Name(service, name), err)
	}
	return s.Create(ctx, service, name, value)
}

// Create stores a value under a name that should not exist yet. When it does,
// because a concurrent run got there first, the stored secret wins and is
// returned with created=false; the caller decides whether a different value
// there is a problem.
func (s *Store) Create(ctx context.Context, service, name, value string) (Secret, bool, error) {
	secretName := s.Name(service, name)
	// No KmsKeyId: the secret takes the AWS-managed aws/secretsmanager key.
	out, err := s.client.CreateSecret(ctx, &secretsmanager.CreateSecretInput{
		Name:         aws.String(secretName),
		SecretString: aws.String(value),
	})
	if err != nil {
		var exists *types.ResourceExistsException
		if errors.As(err, &exists) {
			existing, err := s.Get(ctx, service, name)
			return existing, false, err
		}
		return Secret{}, false, fmt.Errorf("create %s: %w", secretName, err)
	}
	return Secret{Value: value, ARN: aws.ToString(out.ARN)}, true, nil
}

// PutIfChanged stores a value that is derived from another secret, creating
// the secret when it is missing and writing a new version only when the value
// differs. Every version Secrets Manager keeps is one more copy of the key, so
// an unchanged value is not rewritten.
func (s *Store) PutIfChanged(ctx context.Context, service, name, value string) (Secret, error) {
	secretName := s.Name(service, name)

	existing, found, err := s.Lookup(ctx, service, name)
	if err != nil {
		return Secret{}, err
	}
	if !found {
		created, _, err := s.Create(ctx, service, name, value)
		if err != nil {
			return Secret{}, err
		}
		if created.Value != value {
			return Secret{}, fmt.Errorf("%s was created concurrently with a different value", secretName)
		}
		return created, nil
	}
	if existing.Value == value {
		return existing, nil
	}

	out, err := s.client.PutSecretValue(ctx, &secretsmanager.PutSecretValueInput{
		SecretId:     aws.String(existing.ARN),
		SecretString: aws.String(value),
	})
	if err != nil {
		return Secret{}, fmt.Errorf("write %s: %w", secretName, err)
	}
	return Secret{Value: value, ARN: aws.ToString(out.ARN)}, nil
}

// EnsureReplica gives the secret a replica in another region, encrypted with
// that region's AWS-managed aws/secretsmanager key, and reports whether this
// call added it. A replica that is already there, or still being created, is
// left alone, so a steady-state run changes nothing.
//
// A failed replica is reported rather than retried. Secrets Manager fails one
// when the target region already holds a secret of the same name, and
// overwriting that would destroy whatever key it holds.
//
// Nothing is done when the replica region is this store's own region, which is
// the case for a stage root applied in the DR region: the secrets it reads
// there are the replicas.
func (s *Store) EnsureReplica(ctx context.Context, secretARN, replicaRegion string) (bool, error) {
	if replicaRegion == s.region {
		return false, nil
	}

	out, err := s.client.DescribeSecret(ctx, &secretsmanager.DescribeSecretInput{
		SecretId: aws.String(secretARN),
	})
	if err != nil {
		return false, fmt.Errorf("describe %s: %w", secretARN, err)
	}
	if primary := aws.ToString(out.PrimaryRegion); primary != "" && primary != s.region {
		return false, fmt.Errorf("%s is a replica of a secret in %s; replicate it from there", secretARN, primary)
	}

	for _, replica := range out.ReplicationStatus {
		if aws.ToString(replica.Region) != replicaRegion {
			continue
		}
		if replica.Status == types.StatusTypeFailed {
			return false, fmt.Errorf("replica of %s in %s failed: %s; resolve it by hand",
				secretARN, replicaRegion, aws.ToString(replica.StatusMessage))
		}
		return false, nil
	}

	// No KmsKeyId: the replica takes that region's aws/secretsmanager key.
	// ForceOverwriteReplicaSecret stays false so an existing secret of the same
	// name in that region is never replaced.
	if _, err := s.client.ReplicateSecretToRegions(ctx, &secretsmanager.ReplicateSecretToRegionsInput{
		SecretId:          aws.String(secretARN),
		AddReplicaRegions: []types.ReplicaRegionType{{Region: aws.String(replicaRegion)}},
	}); err != nil {
		return false, fmt.Errorf("replicate %s to %s: %w", secretARN, replicaRegion, err)
	}
	return true, nil
}

func (s *Store) get(ctx context.Context, secretName string) (Secret, bool, error) {
	out, err := s.client.GetSecretValue(ctx, &secretsmanager.GetSecretValueInput{
		SecretId: aws.String(secretName),
	})
	if err != nil {
		var notFound *types.ResourceNotFoundException
		if errors.As(err, &notFound) {
			return Secret{}, false, nil
		}
		return Secret{}, false, fmt.Errorf("read %s: %w", secretName, err)
	}
	return Secret{Value: aws.ToString(out.SecretString), ARN: aws.ToString(out.ARN)}, true, nil
}
