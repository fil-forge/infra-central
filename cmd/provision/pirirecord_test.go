package main

import (
	"context"
	"reflect"
	"strings"
	"testing"
)

// A DID cannot be a parameter name, so the host the did:web names is the name
// and the DID is the value.
func TestPiriParameterName(t *testing.T) {
	got, err := piriParameterName("did:web:piri-0.eu-central-3.staging.example.com")
	if err != nil {
		t.Fatalf("piriParameterName: %v", err)
	}
	if want := "piri/piri-0.eu-central-3.staging.example.com"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

// Anything but the did:web of a host carries characters SSM rejects, so it is
// refused rather than mangled into a name.
func TestPiriParameterNameRefusesWhatSSMCannotHold(t *testing.T) {
	cases := map[string]string{
		"a did:key":             "did:key:z6MkExample",
		"a did:web with a port": "did:web:piri.example%3A8443",
		"a did:web with a path": "did:web:piri.example:nodes:one",
		"an upper-case host":    "did:web:Piri.Example",
		"a bare did:web":        "did:web:",
		"not a DID at all":      "piri.example",
		"an empty argument":     "",
	}

	for desc, did := range cases {
		t.Run(desc, func(t *testing.T) {
			_, err := piriParameterName(did)
			if err == nil || !strings.Contains(err.Error(), "did:web") {
				t.Errorf("err = %v, want one naming the did:web requirement", err)
			}
		})
	}
}

func TestRecordedReturnsEveryPiriTheRegionHolds(t *testing.T) {
	store := &fakePublicStore{params: map[string]string{
		"piri/one.example": "did:web:one.example",
		"piri/two.example": "did:web:two.example",
	}}

	got, err := (&piriRecords{store: store}).Recorded(context.Background(), "us-east-9")
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"did:web:one.example", "did:web:two.example"}; !reflect.DeepEqual(got, want) {
		t.Errorf("Recorded() = %v, want %v", got, want)
	}
}

func TestRecordedReturnsNothingForAnUnrecordedRegion(t *testing.T) {
	store := &fakePublicStore{params: map[string]string{}}

	got, err := (&piriRecords{store: store}).Recorded(context.Background(), "us-east-9")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 0 {
		t.Errorf("Recorded() = %v, want nothing", got)
	}
}

func TestRecordWritesTheDIDUnderItsTail(t *testing.T) {
	store := &fakePublicStore{params: map[string]string{}}

	if err := (&piriRecords{store: store}).Record(context.Background(), "us-east-9", "did:web:one.example"); err != nil {
		t.Fatal(err)
	}
	want := map[string]string{"piri/one.example": "did:web:one.example"}
	if !reflect.DeepEqual(store.params, want) {
		t.Errorf("params = %v, want %v", store.params, want)
	}
}

// fakePublicStore holds parameters by their name within one service, which is
// the only service these tests use.
type fakePublicStore struct {
	params map[string]string
}

func (f *fakePublicStore) EnsurePublic(_ context.Context, _, name string, generate func() (string, error)) (string, bool, error) {
	if existing, found := f.params[name]; found {
		return existing, false, nil
	}
	value, err := generate()
	if err != nil {
		return "", false, err
	}
	f.params[name] = value
	return value, true, nil
}

func (f *fakePublicStore) ListPublic(_ context.Context, _, subPrefix string) (map[string]string, error) {
	values := map[string]string{}
	for name, value := range f.params {
		if strings.HasPrefix(name, subPrefix+"/") {
			values[name[strings.LastIndex(name, "/")+1:]] = value
		}
	}
	return values, nil
}
