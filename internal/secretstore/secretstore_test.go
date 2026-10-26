package secretstore

import (
	"context"
	"errors"
	"reflect"
	"testing"
	"time"

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

	// primaryRegion and replicas are what DescribeSecret reports for every
	// secret. An empty primaryRegion means the secret has never been
	// replicated.
	primaryRegion string
	replicas      []types.ReplicationStatusType

	// replicaSteps, when set, replaces replicas call by call: the nth
	// DescribeSecret reports the nth entry, and the last one repeats.
	replicaSteps [][]types.ReplicationStatusType

	// replicateStatus is what ReplicateSecretToRegions reports per region.
	replicateStatus []types.ReplicationStatusType

	creates    []*secretsmanager.CreateSecretInput
	puts       []*secretsmanager.PutSecretValueInput
	describes  int
	replicates []*secretsmanager.ReplicateSecretToRegionsInput
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

func (f *fakeSecrets) DescribeSecret(ctx context.Context, in *secretsmanager.DescribeSecretInput, optFns ...func(*secretsmanager.Options)) (*secretsmanager.DescribeSecretOutput, error) {
	f.describes++
	replicas := f.replicas
	if len(f.replicaSteps) > 0 {
		replicas = f.replicaSteps[min(f.describes, len(f.replicaSteps))-1]
	}
	out := &secretsmanager.DescribeSecretOutput{ARN: in.SecretId, ReplicationStatus: replicas}
	if f.primaryRegion != "" {
		out.PrimaryRegion = aws.String(f.primaryRegion)
	}
	return out, nil
}

func (f *fakeSecrets) ReplicateSecretToRegions(ctx context.Context, in *secretsmanager.ReplicateSecretToRegionsInput, optFns ...func(*secretsmanager.Options)) (*secretsmanager.ReplicateSecretToRegionsOutput, error) {
	f.replicates = append(f.replicates, in)
	return &secretsmanager.ReplicateSecretToRegionsOutput{ARN: in.SecretId, ReplicationStatus: f.replicateStatus}, nil
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
	return &Store{client: client, stage: "test", region: "us-east-2", replicaPoll: time.Millisecond}
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

const anySecretARN = "arn:aws:secretsmanager:us-east-2:111111111111:secret:forge-central/test/svc/key-AbCdEf"

// waitCtx bounds a WaitForReplica call, so a test whose replica never settles
// fails instead of hanging.
func waitCtx(t *testing.T) context.Context {
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	t.Cleanup(cancel)
	return ctx
}

func replicaIn(region string, status types.StatusType) types.ReplicationStatusType {
	return types.ReplicationStatusType{Region: aws.String(region), Status: status}
}

func TestEnsureReplicaAddsAMissingReplicaUnderTheAWSManagedKey(t *testing.T) {
	fake := newFakeSecrets()
	store := newTestStore(fake)

	added, err := store.EnsureReplica(context.Background(), anySecretARN, "eu-central-1")
	if err != nil {
		t.Fatalf("EnsureReplica() error = %v", err)
	}

	// No KmsKeyId, so the replica takes the region's aws/secretsmanager key,
	// and no ForceOverwriteReplicaSecret, so a same-named secret there is kept.
	want := []*secretsmanager.ReplicateSecretToRegionsInput{{
		SecretId:          aws.String(anySecretARN),
		AddReplicaRegions: []types.ReplicaRegionType{{Region: aws.String("eu-central-1")}},
	}}
	if !added || !reflect.DeepEqual(fake.replicates, want) {
		t.Errorf("EnsureReplica() added = %v, replicate calls = %+v; want true, %+v", added, fake.replicates, want)
	}
}

func TestEnsureReplicaAddsTheReplicaBesideOneInAnotherRegion(t *testing.T) {
	fake := newFakeSecrets()
	fake.primaryRegion = "us-east-2"
	fake.replicas = []types.ReplicationStatusType{replicaIn("eu-west-1", types.StatusTypeInSync)}
	store := newTestStore(fake)

	added, err := store.EnsureReplica(context.Background(), anySecretARN, "eu-central-1")
	if err != nil || !added || len(fake.replicates) != 1 {
		t.Errorf("EnsureReplica() = (%v, %v) with %d replicate calls, want (true, nil) with 1", added, err, len(fake.replicates))
	}
}

func TestEnsureReplicaLeavesAnExistingReplicaAlone(t *testing.T) {
	for _, status := range []types.StatusType{types.StatusTypeInSync, types.StatusTypeInProgress} {
		t.Run(string(status), func(t *testing.T) {
			fake := newFakeSecrets()
			fake.primaryRegion = "us-east-2"
			fake.replicas = []types.ReplicationStatusType{replicaIn("eu-central-1", status)}
			store := newTestStore(fake)

			added, err := store.EnsureReplica(context.Background(), anySecretARN, "eu-central-1")
			if err != nil || added || len(fake.replicates) != 0 {
				t.Errorf("EnsureReplica() = (%v, %v) with %d replicate calls, want (false, nil) with none", added, err, len(fake.replicates))
			}
		})
	}
}

func TestEnsureReplicaReportsAFailedReplicaWithoutOverwriting(t *testing.T) {
	fake := newFakeSecrets()
	fake.primaryRegion = "us-east-2"
	failed := replicaIn("eu-central-1", types.StatusTypeFailed)
	failed.StatusMessage = aws.String("a secret with this name already exists")
	fake.replicas = []types.ReplicationStatusType{failed}
	store := newTestStore(fake)

	added, err := store.EnsureReplica(context.Background(), anySecretARN, "eu-central-1")
	if err == nil || added || len(fake.replicates) != 0 {
		t.Errorf("EnsureReplica() = (%v, %v) with %d replicate calls, want an error and no replicate call", added, err, len(fake.replicates))
	}
}

func TestEnsureReplicaRefusesToReplicateAReplica(t *testing.T) {
	fake := newFakeSecrets()
	fake.primaryRegion = "eu-west-1" // the secret this store sees is itself a replica
	store := newTestStore(fake)

	added, err := store.EnsureReplica(context.Background(), anySecretARN, "eu-central-1")
	if err == nil || added || len(fake.replicates) != 0 {
		t.Errorf("EnsureReplica() = (%v, %v) with %d replicate calls, want an error and no replicate call", added, err, len(fake.replicates))
	}
}

func TestEnsureReplicaDoesNothingInTheReplicaRegionItself(t *testing.T) {
	fake := newFakeSecrets()
	store := newTestStore(fake)

	added, err := store.EnsureReplica(context.Background(), anySecretARN, "us-east-2")
	if err != nil || added || fake.describes != 0 || len(fake.replicates) != 0 {
		t.Errorf("EnsureReplica() = (%v, %v) after %d describes and %d replicate calls, want (false, nil) and no calls",
			added, err, fake.describes, len(fake.replicates))
	}
}

func TestEnsureReplicaFailsWhenTheReplicateCallReportsTheRegionFailed(t *testing.T) {
	fake := newFakeSecrets()
	failed := replicaIn("eu-central-1", types.StatusTypeFailed)
	failed.StatusMessage = aws.String("a secret with this name already exists")
	fake.replicateStatus = []types.ReplicationStatusType{failed}
	store := newTestStore(fake)

	added, err := store.EnsureReplica(context.Background(), anySecretARN, "eu-central-1")
	if !errors.Is(err, ErrReplicaFailed) || added {
		t.Errorf("EnsureReplica() = (%v, %v), want (false, %v)", added, err, ErrReplicaFailed)
	}
}

func TestWaitForReplicaReturnsOnceTheReplicaIsInSync(t *testing.T) {
	fake := newFakeSecrets()
	fake.primaryRegion = "us-east-2"
	fake.replicaSteps = [][]types.ReplicationStatusType{
		{replicaIn("eu-central-1", types.StatusTypeInProgress)},
		{replicaIn("eu-central-1", types.StatusTypeInProgress)},
		{replicaIn("eu-central-1", types.StatusTypeInSync)},
	}
	store := newTestStore(fake)

	err := store.WaitForReplica(waitCtx(t), anySecretARN, "eu-central-1")
	if err != nil || fake.describes != 3 {
		t.Errorf("WaitForReplica() = %v after %d describes, want nil after 3", err, fake.describes)
	}
}

func TestWaitForReplicaFailsWhenTheReplicaFails(t *testing.T) {
	fake := newFakeSecrets()
	fake.primaryRegion = "us-east-2"
	fake.replicaSteps = [][]types.ReplicationStatusType{
		{replicaIn("eu-central-1", types.StatusTypeInProgress)},
		{replicaIn("eu-central-1", types.StatusTypeFailed)},
	}
	store := newTestStore(fake)

	if err := store.WaitForReplica(waitCtx(t), anySecretARN, "eu-central-1"); !errors.Is(err, ErrReplicaFailed) {
		t.Errorf("WaitForReplica() error = %v, want %v", err, ErrReplicaFailed)
	}
}

func TestWaitForReplicaKeepsWaitingUntilANewReplicaIsListed(t *testing.T) {
	fake := newFakeSecrets()
	fake.primaryRegion = "us-east-2"
	fake.replicaSteps = [][]types.ReplicationStatusType{
		{replicaIn("eu-west-1", types.StatusTypeInSync)}, // not listed yet
		{replicaIn("eu-west-1", types.StatusTypeInSync), replicaIn("eu-central-1", types.StatusTypeInSync)},
	}
	store := newTestStore(fake)

	err := store.WaitForReplica(waitCtx(t), anySecretARN, "eu-central-1")
	if err != nil || fake.describes != 2 {
		t.Errorf("WaitForReplica() = %v after %d describes, want nil after 2", err, fake.describes)
	}
}

func TestWaitForReplicaReportsAReplicaStillMissingAtTheDeadline(t *testing.T) {
	fake := newFakeSecrets()
	fake.primaryRegion = "us-east-2"
	fake.replicas = []types.ReplicationStatusType{replicaIn("eu-west-1", types.StatusTypeInSync)}
	store := newTestStore(fake)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()

	if err := store.WaitForReplica(ctx, anySecretARN, "eu-central-1"); !errors.Is(err, ErrNoReplica) {
		t.Errorf("WaitForReplica() error = %v, want %v", err, ErrNoReplica)
	}
}

func TestWaitForReplicaGivesUpAtTheDeadline(t *testing.T) {
	fake := newFakeSecrets()
	fake.primaryRegion = "us-east-2"
	fake.replicas = []types.ReplicationStatusType{replicaIn("eu-central-1", types.StatusTypeInProgress)}
	store := newTestStore(fake)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()

	if err := store.WaitForReplica(ctx, anySecretARN, "eu-central-1"); !errors.Is(err, context.DeadlineExceeded) {
		t.Errorf("WaitForReplica() error = %v, want %v", err, context.DeadlineExceeded)
	}
}

func TestWaitForReplicaDoesNothingInTheReplicaRegionItself(t *testing.T) {
	fake := newFakeSecrets()
	store := newTestStore(fake)

	if err := store.WaitForReplica(waitCtx(t), anySecretARN, "us-east-2"); err != nil || fake.describes != 0 {
		t.Errorf("WaitForReplica() = %v after %d describes, want nil and no calls", err, fake.describes)
	}
}
