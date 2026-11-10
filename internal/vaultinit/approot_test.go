package vaultinit

import (
	"context"
	"encoding/json"
	"net/http"
	"reflect"
	"strings"
	"testing"
)

func TestApplianceRootCredentialsVersionIsZeroForARegionWithNoCopy(t *testing.T) {
	client := newHiltKVClient(t, &fakeRootKV{})

	version, err := ApplianceRootCredentialsVersion(context.Background(), client, "eu-central-3")
	if err != nil {
		t.Fatal(err)
	}
	if version != 0 {
		t.Errorf("version = %d, want 0", version)
	}
}

func TestStoreApplianceRootCredentialsWritesBothValuesAsANewVersion(t *testing.T) {
	kv := &fakeRootKV{versions: map[string]int{"eu-central-3": 1}}
	client := newHiltKVClient(t, kv)

	creds := ApplianceRootCredentials{RootToken: "root-token-1", RecoveryKey: "recovery-key-1"}
	version, err := StoreApplianceRootCredentials(context.Background(), client, "eu-central-3", creds)
	if err != nil {
		t.Fatal(err)
	}
	if version != 2 {
		t.Errorf("version = %d, want 2", version)
	}
	want := map[string]map[string]any{
		"eu-central-3": {"root_token": "root-token-1", "recovery_key": "recovery-key-1"},
	}
	if !reflect.DeepEqual(kv.written, want) {
		t.Errorf("written = %v, want %v", kv.written, want)
	}

	stored, err := ApplianceRootCredentialsVersion(context.Background(), client, "eu-central-3")
	if err != nil {
		t.Fatal(err)
	}
	if stored != 2 {
		t.Errorf("stored version = %d, want 2", stored)
	}
}

// A retirement that failed after this step runs it again on the next apply.
func TestRemoveApplianceRootCredentialsToleratesARegionWithNoCopy(t *testing.T) {
	kv := &fakeRootKV{versions: map[string]int{"eu-central-3": 1}}
	client := newHiltKVClient(t, kv)

	for range 2 {
		if err := RemoveApplianceRootCredentials(context.Background(), client, "eu-central-3"); err != nil {
			t.Fatal(err)
		}
	}
	if len(kv.versions) != 0 {
		t.Errorf("versions = %v, want none", kv.versions)
	}
}

// Reading the copy is break-glass: no service policy may reach the mount.
func TestNoServicePolicyNamesTheApplianceRootMount(t *testing.T) {
	policies := map[string]string{
		"hilt":      hiltPolicy(),
		"appliance": appliancePolicy(ApplianceKeyName("eu-central-3")),
	}
	for name, policy := range policies {
		if strings.Contains(policy, ApplianceRootMount) {
			t.Errorf("the %s policy names %s; got:\n%s", name, ApplianceRootMount, policy)
		}
	}
}

// fakeRootKV answers the KV v2 requests the root-credential copy makes on
// ApplianceRootMount.
type fakeRootKV struct {
	versions map[string]int // region -> current version
	written  map[string]map[string]any
}

func (f *fakeRootKV) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	const created = "2026-11-10T00:00:00Z"
	metadata, isMetadata := strings.CutPrefix(r.URL.Path, "/v1/"+ApplianceRootMount+"/metadata/")
	data, isData := strings.CutPrefix(r.URL.Path, "/v1/"+ApplianceRootMount+"/data/")

	switch {
	case isMetadata && r.Method == "GET":
		version, ok := f.versions[metadata]
		if !ok {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		writeJSON(w, map[string]any{"data": map[string]any{
			"current_version": version,
			"created_time":    created,
			"updated_time":    created,
			"versions":        map[string]any{},
		}})

	case isMetadata && r.Method == "DELETE":
		delete(f.versions, metadata)
		w.WriteHeader(http.StatusNoContent)

	case isData && r.Method == "PUT":
		var body struct {
			Data map[string]any `json:"data"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		if f.written == nil {
			f.written = map[string]map[string]any{}
		}
		if f.versions == nil {
			f.versions = map[string]int{}
		}
		f.written[data] = body.Data
		f.versions[data]++
		writeJSON(w, map[string]any{"data": map[string]any{
			"version":       f.versions[data],
			"created_time":  created,
			"deletion_time": "",
			"destroyed":     false,
		}})

	default:
		http.Error(w, "unexpected request: "+r.Method+" "+r.URL.Path, http.StatusNotFound)
	}
}
