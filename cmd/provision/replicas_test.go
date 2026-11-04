package main

import (
	"context"
	"errors"
	"reflect"
	"testing"
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
