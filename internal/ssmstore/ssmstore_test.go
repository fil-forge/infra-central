package ssmstore

import (
	"context"
	"fmt"
	"reflect"
	"sort"
	"strings"
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

	lastGet       *ssm.GetParameterInput
	lastPut       *ssm.PutParameterInput
	deleteBatches [][]string
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

func (f *fakeSSM) GetParametersByPath(ctx context.Context, in *ssm.GetParametersByPathInput, optFns ...func(*ssm.Options)) (*ssm.GetParametersByPathOutput, error) {
	// Real SSM reads the path as a place in a hierarchy rather than as a text
	// prefix, so /a/b holds /a/b/c and has nothing to do with /a/bc. Matching on
	// the trailing slash keeps the fake honest about that: without it a region
	// label that is another one's prefix, us-east-9 against us-east-90, would
	// pass here and fail against AWS.
	prefix := strings.TrimSuffix(aws.ToString(in.Path), "/") + "/"

	var found []types.Parameter
	for name, value := range f.params {
		if strings.HasPrefix(name, prefix) {
			found = append(found, types.Parameter{Name: aws.String(name), Value: aws.String(value)})
		}
	}
	// Real SSM returns no guaranteed order; sorting keeps assertions stable.
	sort.Slice(found, func(i, j int) bool {
		return aws.ToString(found[i].Name) < aws.ToString(found[j].Name)
	})
	return &ssm.GetParametersByPathOutput{Parameters: found}, nil
}

func (f *fakeSSM) DeleteParameters(ctx context.Context, in *ssm.DeleteParametersInput, optFns ...func(*ssm.Options)) (*ssm.DeleteParametersOutput, error) {
	f.deleteBatches = append(f.deleteBatches, in.Names)
	for _, name := range in.Names {
		delete(f.params, name)
	}
	return &ssm.DeleteParametersOutput{}, nil
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

// A region's set of Piri DIDs is one parameter per DID under a sub-prefix, keyed
// by the last segment of the name.
func TestListPublicReturnsEveryValueUnderASubPrefix(t *testing.T) {
	fake := newFakeSSM()
	store := newTestStore(fake)
	fake.params[store.Path("appliance/us-east-9", "piri/z6MkOne")] = "did:key:z6MkOne"
	fake.params[store.Path("appliance/us-east-9", "piri/z6MkTwo")] = "did:key:z6MkTwo"
	fake.params[store.Path("appliance/us-east-9", "unseal-token.accessor")] = "hmac-1"

	got, err := store.ListPublic(context.Background(), "appliance/us-east-9", "piri")
	if err != nil {
		t.Fatalf("ListPublic() error = %v", err)
	}
	want := map[string]string{"z6MkOne": "did:key:z6MkOne", "z6MkTwo": "did:key:z6MkTwo"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("ListPublic() = %v, want %v", got, want)
	}
}

func TestListPublicReturnsNothingForAnAbsentSubPrefix(t *testing.T) {
	store := newTestStore(newFakeSSM())

	got, err := store.ListPublic(context.Background(), "appliance/us-east-9", "piri")
	if err != nil {
		t.Fatalf("ListPublic() error = %v", err)
	}
	if len(got) != 0 {
		t.Errorf("ListPublic() = %v, want nothing", got)
	}
}

func TestDeletePrefixRemovesEveryParameterUnderTheService(t *testing.T) {
	fake := newFakeSSM()
	store := newTestStore(fake)
	fake.params[store.Path("appliance/us-east-9", "unseal-token.accessor")] = "hmac-1"
	fake.params[store.Path("appliance/us-east-9", "hilt-ingot-s3-proof")] = "proof"

	deleted, err := store.DeletePrefix(context.Background(), "appliance/us-east-9")
	if err != nil {
		t.Fatalf("DeletePrefix() error = %v", err)
	}
	if len(deleted) != 2 || len(fake.params) != 0 {
		t.Errorf("DeletePrefix() = %v with %d left, want 2 deleted and none left", deleted, len(fake.params))
	}
}

// Retiring one region must not touch another service's parameters, nor a region
// whose label merely starts with the same characters.
func TestDeletePrefixLeavesOtherServicesAlone(t *testing.T) {
	survivors := []string{"hilt/identity", "appliance/us-east-90/unseal-token.accessor"}
	for _, survivor := range survivors {
		t.Run(survivor, func(t *testing.T) {
			fake := newFakeSSM()
			store := newTestStore(fake)
			fake.params[store.Path("appliance/us-east-9", "unseal-token.accessor")] = "hmac-1"

			path := "/forge-central/test/" + survivor
			fake.params[path] = "keep me"

			if _, err := store.DeletePrefix(context.Background(), "appliance/us-east-9"); err != nil {
				t.Fatalf("DeletePrefix() error = %v", err)
			}
			if _, found := fake.params[path]; !found {
				t.Errorf("%s was deleted, want it left alone", path)
			}
		})
	}
}

// DeleteParameters takes at most ten names, so a larger prefix has to be split.
func TestDeletePrefixBatchesAtTheAPILimit(t *testing.T) {
	fake := newFakeSSM()
	store := newTestStore(fake)
	for i := range 23 {
		fake.params[store.Path("appliance/us-east-9", fmt.Sprintf("key-%02d", i))] = "v"
	}

	if _, err := store.DeletePrefix(context.Background(), "appliance/us-east-9"); err != nil {
		t.Fatalf("DeletePrefix() error = %v", err)
	}
	var sizes []int
	for _, batch := range fake.deleteBatches {
		sizes = append(sizes, len(batch))
	}
	if want := []int{10, 10, 3}; !reflect.DeepEqual(sizes, want) {
		t.Errorf("batch sizes = %v, want %v", sizes, want)
	}
}

func TestDeleteRemovesOnlyTheNamesItIsGiven(t *testing.T) {
	fake := newFakeSSM()
	store := newTestStore(fake)
	accessor := store.Path("appliance/us-east-9", "unseal-token.accessor")
	fake.params[accessor] = "hmac-1"
	fake.params[store.Path("appliance/us-east-9", "hilt-ingot-s3-proof")] = "proof"
	fake.params[store.Path("appliance/us-east-9", "hilt-ingot-s3-proof.issuer")] = "did:key:zHilt"

	deleted, err := store.Delete(context.Background(), "appliance/us-east-9",
		"hilt-ingot-s3-proof", "hilt-ingot-s3-proof.issuer")
	if err != nil {
		t.Fatalf("Delete() error = %v", err)
	}
	if len(deleted) != 2 {
		t.Errorf("Delete() = %v, want the two proof parameters", deleted)
	}
	if _, found := fake.params[accessor]; !found {
		t.Errorf("%s was deleted, want the node's unseal credential left alone", accessor)
	}
}

// A retirement that failed halfway has to be safe to run again, so a name that
// is already gone is neither reported nor an error.
func TestDeleteIgnoresAnAbsentParameter(t *testing.T) {
	fake := newFakeSSM()
	store := newTestStore(fake)

	deleted, err := store.Delete(context.Background(), "appliance/us-east-9", "hilt-ingot-s3-proof")
	if err != nil {
		t.Fatalf("Delete() error = %v", err)
	}
	if len(deleted) != 0 || len(fake.deleteBatches) != 0 {
		t.Errorf("Delete() = %v with %d API calls, want neither", deleted, len(fake.deleteBatches))
	}
}
