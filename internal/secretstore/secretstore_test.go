package secretstore

import (
	"context"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/secretsmanager"
	"github.com/aws/aws-sdk-go-v2/service/secretsmanager/types"
)

// fakeSecrets is an in-memory Secrets Manager. It reproduces the two
// behaviours this package leans on: GetSecretValue fails with
// ResourceNotFoundException for absent names, and CreateSecret fails with
// ResourceExistsException rather than replacing the value.
type fakeSecrets struct {
	values map[string]string

	creates []*secretsmanager.CreateSecretInput
	puts    []*secretsmanager.PutSecretValueInput
}

func newFakeSecrets() *fakeSecrets {
	return &fakeSecrets{values: map[string]string{}}
}

func fakeARN(name string) string {
	return "arn:aws:secretsmanager:us-east-2:111111111111:secret:" + name + "-AbCdEf"
}

func (f *fakeSecrets) GetSecretValue(ctx context.Context, in *secretsmanager.GetSecretValueInput, optFns ...func(*secretsmanager.Options)) (*secretsmanager.GetSecretValueOutput, error) {
	name := aws.ToString(in.SecretId)
	for stored, value := range f.values {
		if name == stored || name == fakeARN(stored) {
			return &secretsmanager.GetSecretValueOutput{
				ARN:          aws.String(fakeARN(stored)),
				SecretString: aws.String(value),
			}, nil
		}
	}
	return nil, &types.ResourceNotFoundException{}
}

func (f *fakeSecrets) CreateSecret(ctx context.Context, in *secretsmanager.CreateSecretInput, optFns ...func(*secretsmanager.Options)) (*secretsmanager.CreateSecretOutput, error) {
	f.creates = append(f.creates, in)
	name := aws.ToString(in.Name)
	if _, exists := f.values[name]; exists {
		return nil, &types.ResourceExistsException{}
	}
	f.values[name] = aws.ToString(in.SecretString)
	return &secretsmanager.CreateSecretOutput{ARN: aws.String(fakeARN(name))}, nil
}

func (f *fakeSecrets) PutSecretValue(ctx context.Context, in *secretsmanager.PutSecretValueInput, optFns ...func(*secretsmanager.Options)) (*secretsmanager.PutSecretValueOutput, error) {
	f.puts = append(f.puts, in)
	for stored := range f.values {
		if aws.ToString(in.SecretId) == fakeARN(stored) {
			f.values[stored] = aws.ToString(in.SecretString)
			return &secretsmanager.PutSecretValueOutput{ARN: in.SecretId}, nil
		}
	}
	return nil, &types.ResourceNotFoundException{}
}

// raceSecrets simulates a concurrent run creating the secret between this
// run's existence check and its write.
type raceSecrets struct {
	*fakeSecrets
	winner string
}

func (r *raceSecrets) CreateSecret(ctx context.Context, in *secretsmanager.CreateSecretInput, optFns ...func(*secretsmanager.Options)) (*secretsmanager.CreateSecretOutput, error) {
	r.values[aws.ToString(in.Name)] = r.winner
	return r.fakeSecrets.CreateSecret(ctx, in, optFns...)
}

func newTestStore(client api) *Store {
	return &Store{client: client, stage: "test"}
}

func TestNameMirrorsTheSSMLayoutWithoutTheLeadingSlash(t *testing.T) {
	store := newTestStore(newFakeSecrets())

	if got, want := store.Name("signing-service", "payer-key"), "forge-central/test/signing-service/payer-key"; got != want {
		t.Errorf("Name() = %q, want %q", got, want)
	}
}

func TestEnsureCreatesAnAbsentSecret(t *testing.T) {
	store := newTestStore(newFakeSecrets())

	secret, created, err := store.Ensure(context.Background(), "svc", "key", func() (string, error) {
		return "fresh", nil
	})
	if err != nil {
		t.Fatalf("Ensure() error = %v", err)
	}

	want := Secret{Value: "fresh", ARN: fakeARN("forge-central/test/svc/key")}
	if secret != want || !created {
		t.Errorf("Ensure() = (%+v, %v), want (%+v, true)", secret, created, want)
	}
}

func TestEnsureUsesTheAWSManagedKey(t *testing.T) {
	fake := newFakeSecrets()
	store := newTestStore(fake)

	if _, _, err := store.Ensure(context.Background(), "svc", "key", func() (string, error) {
		return "fresh", nil
	}); err != nil {
		t.Fatalf("Ensure() error = %v", err)
	}

	if keyID := aws.ToString(fake.creates[0].KmsKeyId); keyID != "" {
		t.Errorf("CreateSecret named KMS key %q; want none, so the AWS-managed key that no destroy can remove is used", keyID)
	}
}

func TestEnsureKeepsTheExistingValueWithoutGenerating(t *testing.T) {
	fake := newFakeSecrets()
	store := newTestStore(fake)
	fake.values[store.Name("svc", "key")] = "minted-earlier"

	secret, created, err := store.Ensure(context.Background(), "svc", "key", func() (string, error) {
		t.Fatal("generate was called even though the secret exists")
		return "", nil
	})
	if err != nil {
		t.Fatalf("Ensure() error = %v", err)
	}

	want := Secret{Value: "minted-earlier", ARN: fakeARN("forge-central/test/svc/key")}
	if secret != want || created {
		t.Errorf("Ensure() = (%+v, %v), want (%+v, false)", secret, created, want)
	}
}

func TestEnsureYieldsToAConcurrentWriter(t *testing.T) {
	race := &raceSecrets{fakeSecrets: newFakeSecrets(), winner: "theirs"}
	store := newTestStore(race)

	secret, created, err := store.Ensure(context.Background(), "svc", "key", func() (string, error) {
		return "ours", nil
	})
	if err != nil {
		t.Fatalf("Ensure() error = %v", err)
	}
	if secret.Value != "theirs" || created {
		t.Errorf("Ensure() = (%q, %v), want (%q, false)", secret.Value, created, "theirs")
	}
}

func TestPutIfChangedCreatesAnAbsentSecret(t *testing.T) {
	fake := newFakeSecrets()
	store := newTestStore(fake)

	if _, err := store.PutIfChanged(context.Background(), "svc", "derived", "value"); err != nil {
		t.Fatalf("PutIfChanged() error = %v", err)
	}
	if got := fake.values["forge-central/test/svc/derived"]; got != "value" {
		t.Errorf("stored %q, want %q", got, "value")
	}
}

func TestPutIfChangedSkipsAnUnchangedValue(t *testing.T) {
	fake := newFakeSecrets()
	store := newTestStore(fake)
	fake.values[store.Name("svc", "derived")] = "value"

	if _, err := store.PutIfChanged(context.Background(), "svc", "derived", "value"); err != nil {
		t.Fatalf("PutIfChanged() error = %v", err)
	}
	if len(fake.puts) != 0 {
		t.Errorf("PutSecretValue called %d times for an unchanged value, want 0", len(fake.puts))
	}
}

func TestPutIfChangedWritesAChangedValue(t *testing.T) {
	fake := newFakeSecrets()
	store := newTestStore(fake)
	fake.values[store.Name("svc", "derived")] = "old"

	if _, err := store.PutIfChanged(context.Background(), "svc", "derived", "new"); err != nil {
		t.Fatalf("PutIfChanged() error = %v", err)
	}
	if got := fake.values["forge-central/test/svc/derived"]; got != "new" {
		t.Errorf("stored %q, want %q", got, "new")
	}
}

func TestPutIfChangedRefusesAConcurrentDifferentValue(t *testing.T) {
	race := &raceSecrets{fakeSecrets: newFakeSecrets(), winner: "theirs"}
	store := newTestStore(race)

	if _, err := store.PutIfChanged(context.Background(), "svc", "derived", "ours"); err == nil {
		t.Error("PutIfChanged() succeeded although a concurrent run stored a different value")
	}
}

func TestGetFailsForAnAbsentSecret(t *testing.T) {
	store := newTestStore(newFakeSecrets())

	if _, err := store.Get(context.Background(), "svc", "missing"); err == nil {
		t.Error("Get() succeeded for a secret that does not exist")
	}
}
