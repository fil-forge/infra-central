package ssmstore

import (
	"context"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ssm"
	"github.com/aws/aws-sdk-go-v2/service/ssm/types"
)

// fakeSSM is an in-memory parameter store. It reproduces the two behaviours
// this package leans on: GetParameter fails with ParameterNotFound for absent
// names, and PutParameter with Overwrite=false fails with
// ParameterAlreadyExists rather than replacing the value.
type fakeSSM struct {
	params map[string]string

	lastGet *ssm.GetParameterInput
	lastPut *ssm.PutParameterInput
}

func newFakeSSM() *fakeSSM {
	return &fakeSSM{params: map[string]string{}}
}

func (f *fakeSSM) GetParameter(ctx context.Context, in *ssm.GetParameterInput, optFns ...func(*ssm.Options)) (*ssm.GetParameterOutput, error) {
	f.lastGet = in
	value, ok := f.params[aws.ToString(in.Name)]
	if !ok {
		return nil, &types.ParameterNotFound{}
	}
	return &ssm.GetParameterOutput{
		Parameter: &types.Parameter{Value: aws.String(value)},
	}, nil
}

func (f *fakeSSM) PutParameter(ctx context.Context, in *ssm.PutParameterInput, optFns ...func(*ssm.Options)) (*ssm.PutParameterOutput, error) {
	f.lastPut = in
	name := aws.ToString(in.Name)
	if _, exists := f.params[name]; exists && !aws.ToBool(in.Overwrite) {
		return nil, &types.ParameterAlreadyExists{}
	}
	f.params[name] = aws.ToString(in.Value)
	return &ssm.PutParameterOutput{}, nil
}

func newTestStore(client api) *Store {
	return &Store{client: client, stage: "test"}
}

func TestEnsureSecretCreatesAnAbsentParameter(t *testing.T) {
	fake := newFakeSSM()
	store := newTestStore(fake)

	value, created, err := store.EnsureSecret(context.Background(), "svc", "key", func() (string, error) {
		return "fresh", nil
	})
	if err != nil {
		t.Fatalf("EnsureSecret() error = %v", err)
	}
	if value != "fresh" || !created {
		t.Errorf("EnsureSecret() = (%q, %v), want (%q, true)", value, created, "fresh")
	}
}

func TestEnsureSecretWritesWithoutOverwrite(t *testing.T) {
	fake := newFakeSSM()
	store := newTestStore(fake)

	if _, _, err := store.EnsureSecret(context.Background(), "svc", "key", func() (string, error) {
		return "fresh", nil
	}); err != nil {
		t.Fatalf("EnsureSecret() error = %v", err)
	}

	if aws.ToBool(fake.lastPut.Overwrite) {
		t.Error("EnsureSecret wrote with Overwrite=true; an existing parameter would have been replaced")
	}
	if fake.lastPut.Type != types.ParameterTypeSecureString {
		t.Errorf("EnsureSecret wrote type %q, want SecureString", fake.lastPut.Type)
	}
}

func TestEnsureSecretKeepsTheExistingValueWithoutGenerating(t *testing.T) {
	fake := newFakeSSM()
	store := newTestStore(fake)
	fake.params[store.Path("svc", "key")] = "minted-earlier"

	value, created, err := store.EnsureSecret(context.Background(), "svc", "key", func() (string, error) {
		t.Fatal("generate was called even though the parameter exists")
		return "", nil
	})
	if err != nil {
		t.Fatalf("EnsureSecret() error = %v", err)
	}
	if value != "minted-earlier" || created {
		t.Errorf("EnsureSecret() = (%q, %v), want (%q, false)", value, created, "minted-earlier")
	}
}

// raceSSM simulates a concurrent run creating the parameter between this run's
// existence check and its write.
type raceSSM struct {
	*fakeSSM
}

func (r *raceSSM) PutParameter(ctx context.Context, in *ssm.PutParameterInput, optFns ...func(*ssm.Options)) (*ssm.PutParameterOutput, error) {
	if _, exists := r.params[aws.ToString(in.Name)]; !exists {
		r.params[aws.ToString(in.Name)] = "raced-in-first"
	}
	return r.fakeSSM.PutParameter(ctx, in, optFns...)
}

func TestEnsureSecretYieldsToAConcurrentWriter(t *testing.T) {
	race := &raceSSM{fakeSSM: newFakeSSM()}
	store := newTestStore(race)

	value, created, err := store.EnsureSecret(context.Background(), "svc", "key", func() (string, error) {
		return "loser", nil
	})
	if err != nil {
		t.Fatalf("EnsureSecret() error = %v", err)
	}
	if value != "raced-in-first" || created {
		t.Errorf("EnsureSecret() = (%q, %v), want (%q, false)", value, created, "raced-in-first")
	}
}

func TestEnsureReadsDecryptOnlyForSecureStrings(t *testing.T) {
	cases := map[string]struct {
		ensure      func(*Store) error
		wantDecrypt bool
	}{
		"EnsureSecret decrypts": {
			ensure: func(s *Store) error {
				_, _, err := s.EnsureSecret(context.Background(), "svc", "key", func() (string, error) { return "v", nil })
				return err
			},
			wantDecrypt: true,
		},
		"EnsurePublic does not decrypt": {
			ensure: func(s *Store) error {
				_, _, err := s.EnsurePublic(context.Background(), "svc", "key", func() (string, error) { return "v", nil })
				return err
			},
			wantDecrypt: false,
		},
	}

	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			fake := newFakeSSM()
			if err := tc.ensure(newTestStore(fake)); err != nil {
				t.Fatalf("ensure error = %v", err)
			}
			if got := aws.ToBool(fake.lastGet.WithDecryption); got != tc.wantDecrypt {
				t.Errorf("GetParameter WithDecryption = %v, want %v", got, tc.wantDecrypt)
			}
		})
	}
}

func TestPutPublicOverwritesAnExistingParameter(t *testing.T) {
	fake := newFakeSSM()
	store := newTestStore(fake)
	fake.params[store.Path("svc", "key")] = "stale"

	if err := store.PutPublic(context.Background(), "svc", "key", "derived"); err != nil {
		t.Fatalf("PutPublic() error = %v", err)
	}
	if got := fake.params[store.Path("svc", "key")]; got != "derived" {
		t.Errorf("stored value = %q, want %q", got, "derived")
	}
}

func TestPutSecretOverwritesAnExistingParameter(t *testing.T) {
	fake := newFakeSSM()
	store := newTestStore(fake)
	fake.params[store.Path("svc", "key")] = "old-secret-id"

	if err := store.PutSecret(context.Background(), "svc", "key", "new-secret-id"); err != nil {
		t.Fatalf("PutSecret() error = %v", err)
	}
	if got := fake.params[store.Path("svc", "key")]; got != "new-secret-id" {
		t.Errorf("stored value = %q, want %q", got, "new-secret-id")
	}
}

func TestGetSecretFailsForAMissingParameter(t *testing.T) {
	store := newTestStore(newFakeSSM())

	if _, err := store.GetSecret(context.Background(), "svc", "absent"); err == nil {
		t.Fatal("GetSecret() returned no error for a missing parameter")
	}
}

func TestLookupSecretReportsAMissingParameterWithoutFailing(t *testing.T) {
	store := newTestStore(newFakeSSM())

	value, found, err := store.LookupSecret(context.Background(), "svc", "absent")
	if err != nil {
		t.Fatalf("LookupSecret() error = %v", err)
	}
	if found || value != "" {
		t.Errorf("LookupSecret() = (%q, %v), want (%q, false)", value, found, "")
	}
}
