package main

import (
	"context"
	"reflect"
	"strings"
	"testing"

	"github.com/fil-forge/infra-central/internal/keygen"
	"github.com/fil-forge/infra-central/internal/secretstore"
)

// fakeReplicator records the ARNs it was asked to replicate and treats those in
// existing as already replicated.
type fakeReplicator struct {
	existing map[string]bool
	asked    []string
}

func (f *fakeReplicator) Name(service, name string) string {
	return "forge-central/test/" + service + "/" + name
}

func (f *fakeReplicator) EnsureReplica(ctx context.Context, secretARN, replicaRegion string) (bool, error) {
	f.asked = append(f.asked, secretARN+" -> "+replicaRegion)
	return !f.existing[secretARN], nil
}

func seededSecrets() map[string]map[string]string {
	return map[string]map[string]string{
		"sprue":           {"identity": "arn:sprue/identity"},
		"delegator":       {"identity": "arn:delegator/identity", "transactor-key": "arn:delegator/transactor-key"},
		"signing-service": {"payer-key": "arn:signing-service/payer-key"},
	}
}

func TestReplicateKeysReplicatesEverySecretWalletsFirst(t *testing.T) {
	keys := &fakeReplicator{}
	resp := &Response{Secrets: seededSecrets()}

	if err := replicateKeys(context.Background(), keys, "eu-central-1", resp); err != nil {
		t.Fatalf("replicateKeys() error = %v", err)
	}

	want := []string{
		"arn:delegator/transactor-key -> eu-central-1",
		"arn:signing-service/payer-key -> eu-central-1",
		"arn:delegator/identity -> eu-central-1",
		"arn:sprue/identity -> eu-central-1",
	}
	if !reflect.DeepEqual(keys.asked, want) {
		t.Errorf("EnsureReplica calls = %v, want %v", keys.asked, want)
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
		Secrets:       seededSecrets(),
		ReplicaRegion: "eu-central-1",
		Replicated:    []string{"forge-central/test/signing-service/payer-key"},
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
	if len(keys.asked) != 0 || resp.ReplicaRegion != "" {
		t.Errorf("replicateKeys() asked for %v and set region %q, want nothing", keys.asked, resp.ReplicaRegion)
	}
}

func TestReplicatedKeysCoverEveryKeyTheIssueNames(t *testing.T) {
	var got []string
	for _, key := range replicatedKeys() {
		got = append(got, key.service+"/"+key.name)
	}

	want := []string{
		"signing-service/payer-key",
		"delegator/transactor-key",
		"sprue/identity",
		"hilt/identity",
		"swarf/identity",
		"delegator/identity",
		"delegator/identity-multibase",
		"signing-service/identity",
		"signing-service/identity-multibase",
		"indexer/identity",
		"etracker/identity",
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("replicatedKeys() = %v, want %v", got, want)
	}
}

// mapKeys is a keyReader over service/name -> value.
type mapKeys map[string]string

func (m mapKeys) Lookup(ctx context.Context, service, name string) (secretstore.Secret, bool, error) {
	value, ok := m[service+"/"+name]
	return secretstore.Secret{Value: value}, ok, nil
}

var testReplicatedKey = replicatedKey{
	service: "svc",
	name:    "key",
	derive:  func(value string) (string, error) { return testPublicHalves[value], nil },
}

func TestCompareReplicas(t *testing.T) {
	testCases := []struct {
		name    string
		replica mapKeys
		want    ReplicaCheck
	}{
		{
			name:    "matches a replica deriving the primary's public half",
			replica: mapKeys{"svc/key": "k1"},
			want:    ReplicaCheck{Key: "svc/key", Primary: "public-of-k1", Replica: "public-of-k1", Match: true},
		},
		{
			name:    "fails a replica deriving a different public half",
			replica: mapKeys{"svc/key": "k2"},
			want:    ReplicaCheck{Key: "svc/key", Primary: "public-of-k1", Replica: "public-of-k2"},
		},
		{
			name:    "fails a missing replica",
			replica: mapKeys{},
			want:    ReplicaCheck{Key: "svc/key", Primary: "public-of-k1"},
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			primary := mapKeys{"svc/key": "k1"}

			got, err := compareReplicas(context.Background(), primary, tc.replica, []replicatedKey{testReplicatedKey})
			if err != nil {
				t.Fatalf("compareReplicas() error = %v", err)
			}
			if want := []ReplicaCheck{tc.want}; !reflect.DeepEqual(got, want) {
				t.Errorf("compareReplicas() = %+v, want %+v", got, want)
			}
		})
	}
}

func TestCompareReplicasFailsForAKeyMissingFromThePrimary(t *testing.T) {
	_, err := compareReplicas(context.Background(), mapKeys{}, mapKeys{"svc/key": "k1"}, []replicatedKey{testReplicatedKey})
	if err == nil || !strings.Contains(err.Error(), "svc/key is missing from the primary region") {
		t.Errorf("compareReplicas() error = %v, want one naming the missing key", err)
	}
}

func TestCompareReplicasNeverReportsTheKey(t *testing.T) {
	primary := mapKeys{"svc/key": "very-secret-value"}
	replica := mapKeys{"svc/key": "k2"}

	got, err := compareReplicas(context.Background(), primary, replica, []replicatedKey{testReplicatedKey})
	if err != nil {
		t.Fatalf("compareReplicas() error = %v", err)
	}
	if rendered := strings.Join([]string{got[0].Key, got[0].Primary, got[0].Replica}, " "); strings.Contains(rendered, "very-secret-value") {
		t.Errorf("compareReplicas() = %+v, which contains the primary's private value", got)
	}
}

func TestMultibaseReplicaDerivesTheIdentityDID(t *testing.T) {
	id, err := keygen.GenerateIdentity()
	if err != nil {
		t.Fatal(err)
	}

	if got, err := deriveMultibaseDID(id.Multibase); err != nil || got != id.DID {
		t.Errorf("deriveMultibaseDID() = (%q, %v), want (%q, nil)", got, err, id.DID)
	}
}
