package main

import (
	"context"
	"reflect"
	"strings"
	"testing"

	"github.com/fil-forge/infra-central/internal/keygen"
	"github.com/fil-forge/infra-central/internal/secretstore"
)

// fakeLegacy is the SSM side of a key move: SecureStrings and public records,
// both keyed by service/name.
type fakeLegacy struct {
	secrets map[string]string
	public  map[string]string
}

func (f *fakeLegacy) LookupSecret(ctx context.Context, service, name string) (string, bool, error) {
	value, ok := f.secrets[service+"/"+name]
	return value, ok, nil
}

func (f *fakeLegacy) LookupPublic(ctx context.Context, service, name string) (string, bool, error) {
	value, ok := f.public[service+"/"+name]
	return value, ok, nil
}

func (f *fakeLegacy) Delete(ctx context.Context, service string, names ...string) ([]string, error) {
	var deleted []string
	for _, name := range names {
		if _, ok := f.secrets[service+"/"+name]; ok {
			delete(f.secrets, service+"/"+name)
			deleted = append(deleted, service+"/"+name)
		}
	}
	return deleted, nil
}

// fakeKeys is the Secrets Manager side, keyed by service/name.
type fakeKeys struct {
	values map[string]string
}

func (f *fakeKeys) Lookup(ctx context.Context, service, name string) (secretstore.Secret, bool, error) {
	value, ok := f.values[service+"/"+name]
	return secretstore.Secret{Value: value, ARN: "arn:" + service + "/" + name}, ok, nil
}

func (f *fakeKeys) Create(ctx context.Context, service, name, value string) (secretstore.Secret, bool, error) {
	if existing, ok := f.values[service+"/"+name]; ok {
		return secretstore.Secret{Value: existing, ARN: "arn:" + service + "/" + name}, false, nil
	}
	f.values[service+"/"+name] = value
	return secretstore.Secret{Value: value, ARN: "arn:" + service + "/" + name}, true, nil
}

// testPublicHalves stands in for deriving an address. Like a real one, the
// public half shares nothing with the private value.
var testPublicHalves = map[string]string{
	"k1":                "public-of-k1",
	"k2":                "public-of-k2",
	"very-secret-value": "public-of-the-secret",
}

var testKeySpec = keySpec{
	service:     "svc",
	name:        "key",
	publicName:  "key.address",
	derive:      func(value string) (string, error) { return testPublicHalves[value], nil },
	legacyNames: []string{"key", "key-copy"},
}

// keyMoveOutcome is everything ensureKey can change, compared in one go.
type keyMoveOutcome struct {
	Failed  bool
	Created bool
	Secrets map[string]string
	SSM     map[string]string
}

func TestEnsureKey(t *testing.T) {
	testCases := []struct {
		name       string
		secrets    map[string]string
		ssm        map[string]string
		public     map[string]string
		wantResult keyMoveOutcome
	}{
		{
			name:    "copies a key found only in SSM and deletes every SSM copy",
			secrets: map[string]string{},
			ssm:     map[string]string{"svc/key": "k1", "svc/key-copy": "k1-copy"},
			public:  map[string]string{"svc/key.address": "public-of-k1"},
			wantResult: keyMoveOutcome{
				Secrets: map[string]string{"svc/key": "k1"},
				SSM:     map[string]string{},
			},
		},
		{
			name:    "refuses a key whose public record does not match",
			secrets: map[string]string{},
			ssm:     map[string]string{"svc/key": "k1"},
			public:  map[string]string{"svc/key.address": "public-of-other"},
			wantResult: keyMoveOutcome{
				Failed:  true,
				Secrets: map[string]string{},
				SSM:     map[string]string{"svc/key": "k1"},
			},
		},
		{
			name:    "refuses a key with no public record",
			secrets: map[string]string{},
			ssm:     map[string]string{"svc/key": "k1"},
			public:  map[string]string{},
			wantResult: keyMoveOutcome{
				Failed:  true,
				Secrets: map[string]string{},
				SSM:     map[string]string{"svc/key": "k1"},
			},
		},
		{
			name:    "finishes a move that stopped before deleting the SSM copy",
			secrets: map[string]string{"svc/key": "k1"},
			ssm:     map[string]string{"svc/key": "k1"},
			public:  map[string]string{"svc/key.address": "public-of-k1"},
			wantResult: keyMoveOutcome{
				Secrets: map[string]string{"svc/key": "k1"},
				SSM:     map[string]string{},
			},
		},
		{
			name:    "refuses to delete an SSM copy that differs from the secret",
			secrets: map[string]string{"svc/key": "k1"},
			ssm:     map[string]string{"svc/key": "k2"},
			public:  map[string]string{"svc/key.address": "public-of-k1"},
			wantResult: keyMoveOutcome{
				Failed:  true,
				Secrets: map[string]string{"svc/key": "k1"},
				SSM:     map[string]string{"svc/key": "k2"},
			},
		},
		{
			name:    "mints a key that exists nowhere",
			secrets: map[string]string{},
			ssm:     map[string]string{},
			public:  map[string]string{},
			wantResult: keyMoveOutcome{
				Created: true,
				Secrets: map[string]string{"svc/key": "minted"},
				SSM:     map[string]string{},
			},
		},
		{
			name:    "keeps a key already in Secrets Manager",
			secrets: map[string]string{"svc/key": "k1"},
			ssm:     map[string]string{},
			public:  map[string]string{"svc/key.address": "public-of-k1"},
			wantResult: keyMoveOutcome{
				Secrets: map[string]string{"svc/key": "k1"},
				SSM:     map[string]string{},
			},
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			keys := &fakeKeys{values: tc.secrets}
			legacy := &fakeLegacy{secrets: tc.ssm, public: tc.public}

			_, created, err := ensureKey(context.Background(), keys, legacy, testKeySpec, func() (string, error) {
				return "minted", nil
			})

			got := keyMoveOutcome{Failed: err != nil, Created: created, Secrets: keys.values, SSM: legacy.secrets}
			if !reflect.DeepEqual(got, tc.wantResult) {
				t.Errorf("ensureKey() outcome = %+v, want %+v (err = %v)", got, tc.wantResult, err)
			}
		})
	}
}

func TestEnsureKeyNeverPutsTheKeyInAnError(t *testing.T) {
	keys := &fakeKeys{values: map[string]string{}}
	legacy := &fakeLegacy{
		secrets: map[string]string{"svc/key": "very-secret-value"},
		public:  map[string]string{"svc/key.address": "public-of-other"},
	}

	_, _, err := ensureKey(context.Background(), keys, legacy, testKeySpec, func() (string, error) {
		return "minted", nil
	})
	if err == nil {
		t.Fatal("ensureKey() succeeded for a mismatched key")
	}
	if strings.Contains(err.Error(), "very-secret-value") {
		t.Errorf("ensureKey() error %q contains the key", err)
	}
}

func TestIdentitySpecDeletesTheMultibaseCopy(t *testing.T) {
	testCases := map[string][]string{
		"sprue":           {"identity"},
		"delegator":       {"identity", "identity-multibase"},
		"signing-service": {"identity", "identity-multibase"},
	}
	for service, want := range testCases {
		t.Run(service, func(t *testing.T) {
			if got := identitySpec(service).legacyNames; !reflect.DeepEqual(got, want) {
				t.Errorf("identitySpec(%q).legacyNames = %v, want %v", service, got, want)
			}
		})
	}
}

func TestIdentitySpecDerivesTheDID(t *testing.T) {
	id, err := keygen.GenerateIdentity()
	if err != nil {
		t.Fatal(err)
	}

	if got, err := identitySpec("sprue").derive(string(id.PrivatePEM)); err != nil || got != id.DID {
		t.Errorf("derive() = (%q, %v), want (%q, nil)", got, err, id.DID)
	}
}

func TestWalletSpecDerivesTheAddress(t *testing.T) {
	for _, spec := range wallets {
		t.Run(spec.service+"/"+spec.name, func(t *testing.T) {
			w, err := keygen.GenerateEVMWallet()
			if err != nil {
				t.Fatal(err)
			}

			if got, err := spec.keySpec().derive(spec.encode(w)); err != nil || got != w.Address {
				t.Errorf("derive() = (%q, %v), want (%q, nil)", got, err, w.Address)
			}
		})
	}
}
