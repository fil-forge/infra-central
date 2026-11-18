package main

import (
	"context"
	"errors"
	"reflect"
	"slices"
	"testing"
	"time"

	"github.com/aws/smithy-go"
)

// fakeReplicator records each replicate and wait call in order, treats the
// ARNs in existing as already replicated, and fails the wait for waitErr.
type fakeReplicator struct {
	existing map[string]bool
	waitErr  map[string]error
	asked    []string
}

func (f *fakeReplicator) Name(service, name string) string {
	return "forge-central/test/" + service + "/" + name
}

func (f *fakeReplicator) EnsureReplica(ctx context.Context, secretARN, replicaRegion string) (bool, error) {
	f.asked = append(f.asked, "replicate "+secretARN+" -> "+replicaRegion)
	return !f.existing[secretARN], nil
}

func (f *fakeReplicator) WaitForReplica(ctx context.Context, secretARN, replicaRegion string) error {
	f.asked = append(f.asked, "wait "+secretARN+" -> "+replicaRegion)
	return f.waitErr[secretARN]
}

func seededSecrets() map[string]map[string]string {
	return map[string]map[string]string{
		"sprue":           {"identity": "arn:sprue/identity"},
		"delegator":       {"identity": "arn:delegator/identity", "transactor-key": "arn:delegator/transactor-key"},
		"signing-service": {"payer-key": "arn:signing-service/payer-key"},
	}
}

func TestReplicateKeysReplicatesEverySecretWalletsFirstThenWaitsForEach(t *testing.T) {
	keys := &fakeReplicator{}
	resp := &Response{Secrets: seededSecrets()}

	if err := replicateKeys(context.Background(), keys, "eu-central-1", resp); err != nil {
		t.Fatalf("replicateKeys() error = %v", err)
	}

	want := []string{
		"replicate arn:delegator/transactor-key -> eu-central-1",
		"replicate arn:signing-service/payer-key -> eu-central-1",
		"replicate arn:delegator/identity -> eu-central-1",
		"replicate arn:sprue/identity -> eu-central-1",
		"wait arn:delegator/transactor-key -> eu-central-1",
		"wait arn:signing-service/payer-key -> eu-central-1",
		"wait arn:delegator/identity -> eu-central-1",
		"wait arn:sprue/identity -> eu-central-1",
	}
	if !reflect.DeepEqual(keys.asked, want) {
		t.Errorf("replicator calls = %v, want %v", keys.asked, want)
	}
}

func TestReplicateKeysFailsWhenAReplicaDoesNotSync(t *testing.T) {
	notSynced := errors.New("replica failed")
	keys := &fakeReplicator{waitErr: map[string]error{"arn:sprue/identity": notSynced}}
	resp := &Response{Secrets: seededSecrets()}

	if err := replicateKeys(context.Background(), keys, "eu-central-1", resp); !errors.Is(err, notSynced) {
		t.Errorf("replicateKeys() error = %v, want %v", err, notSynced)
	}
}

func TestReplicateKeysReportsOnlyTheReplicasItAdded(t *testing.T) {
	keys := &fakeReplicator{existing: map[string]bool{
		"arn:delegator/transactor-key": true,
		"arn:delegator/identity":       true,
		"arn:sprue/identity":           true,
	}}
	resp := &Response{Secrets: seededSecrets()}

	if err := replicateKeys(context.Background(), keys, "eu-central-1", resp); err != nil {
		t.Fatalf("replicateKeys() error = %v", err)
	}

	want := Response{
		Secrets:             seededSecrets(),
		BackupReplicaRegion: "eu-central-1",
		Replicated:          []string{"forge-central/test/signing-service/payer-key"},
	}
	if !reflect.DeepEqual(*resp, want) {
		t.Errorf("response = %+v, want %+v", *resp, want)
	}
}

func TestReplicateKeysDoesNothingWithoutAReplicaRegion(t *testing.T) {
	keys := &fakeReplicator{}
	resp := &Response{Secrets: seededSecrets()}

	if err := replicateKeys(context.Background(), keys, "", resp); err != nil {
		t.Fatalf("replicateKeys() error = %v", err)
	}
	if len(keys.asked) != 0 || resp.BackupReplicaRegion != "" {
		t.Errorf("replicateKeys() asked for %v and set region %q, want nothing", keys.asked, resp.BackupReplicaRegion)
	}
}

// scriptedReplicator answers EnsureReplica with errs in turn, then succeeds,
// and counts the calls.
type scriptedReplicator struct {
	fakeReplicator
	errs  []error
	calls int
}

func (f *scriptedReplicator) EnsureReplica(ctx context.Context, secretARN, replicaRegion string) (bool, error) {
	f.calls++
	if f.calls <= len(f.errs) {
		return false, f.errs[f.calls-1]
	}
	return true, nil
}

var errDenied = &smithy.GenericAPIError{
	Code:    "AccessDeniedException",
	Message: "no identity-based policy allows the secretsmanager:ReplicateSecretToRegions action",
}

var fastGrantRetry = grantRetry{interval: time.Millisecond, budget: time.Second}

func TestEnsureReplicaOnceGrantedRetriesWhileDenied(t *testing.T) {
	keys := &scriptedReplicator{errs: []error{errDenied, errDenied}}

	added, err := ensureReplicaOnceGranted(context.Background(), keys, "arn:sprue/identity", "eu-central-1", fastGrantRetry)

	type outcome struct {
		Added bool
		Err   error
		Calls int
	}
	if got, want := (outcome{added, err, keys.calls}), (outcome{true, nil, 3}); got != want {
		t.Errorf("outcome = %+v, want %+v", got, want)
	}
}

func TestEnsureReplicaOnceGrantedFailsWithTheDenialWhenTheBudgetRunsOut(t *testing.T) {
	keys := &scriptedReplicator{errs: slices.Repeat([]error{errDenied}, 1000)}
	retry := grantRetry{interval: time.Millisecond, budget: 20 * time.Millisecond}

	_, err := ensureReplicaOnceGranted(context.Background(), keys, "arn:sprue/identity", "eu-central-1", retry)

	if !errors.Is(err, errDenied) {
		t.Errorf("error = %v, want it to wrap %v", err, errDenied)
	}
}

func TestEnsureReplicaOnceGrantedDoesNotRetryOtherErrors(t *testing.T) {
	keys := &scriptedReplicator{errs: []error{errors.New("throttled"), errDenied}}

	_, _ = ensureReplicaOnceGranted(context.Background(), keys, "arn:sprue/identity", "eu-central-1", fastGrantRetry)

	if keys.calls != 1 {
		t.Errorf("EnsureReplica calls = %d, want 1", keys.calls)
	}
}

func TestEnsureReplicaOnceGrantedStopsWhenTheContextEnds(t *testing.T) {
	keys := &scriptedReplicator{errs: slices.Repeat([]error{errDenied}, 1000)}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	retry := grantRetry{interval: time.Hour, budget: 2 * time.Hour}

	_, err := ensureReplicaOnceGranted(ctx, keys, "arn:sprue/identity", "eu-central-1", retry)

	if !errors.Is(err, context.Canceled) {
		t.Errorf("error = %v, want it to wrap %v", err, context.Canceled)
	}
}
