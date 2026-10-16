package vaultinit

import (
	"context"
	"net/http"
	"reflect"
	"sort"
	"strings"
	"testing"

	"github.com/openbao/openbao/api/v2"
)

// hilt nests a tenant's access-key signers under the tenant's own path, so a
// listing that stopped at the first level would leave them behind.
func TestListHiltSecretsWalksNestedFolders(t *testing.T) {
	kv := &fakeHiltKV{secrets: map[string]bool{
		"tenant/did:plc:a":                  true,
		"tenant/did:plc:a/wrap":             true,
		"tenant/did:plc:a/access-key/key-1": true,
		"tenant/did:plc:b":                  true,
	}}

	got, err := ListHiltSecrets(context.Background(), newHiltKVClient(t, kv))
	if err != nil {
		t.Fatal(err)
	}
	sort.Strings(got)

	want := []string{
		"tenant/did:plc:a",
		"tenant/did:plc:a/access-key/key-1",
		"tenant/did:plc:a/wrap",
		"tenant/did:plc:b",
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("ListHiltSecrets() = %v, want %v", got, want)
	}
}

// A stage with no tenants yet answers the list with a 404.
func TestListHiltSecretsReturnsNothingForAnEmptyMount(t *testing.T) {
	got, err := ListHiltSecrets(context.Background(), newHiltKVClient(t, &fakeHiltKV{}))
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 0 {
		t.Errorf("ListHiltSecrets() = %v, want none", got)
	}
}

func TestDestroyHiltSecretDeletesTheMetadata(t *testing.T) {
	kv := &fakeHiltKV{secrets: map[string]bool{"tenant/did:plc:a": true}}

	if err := DestroyHiltSecret(context.Background(), newHiltKVClient(t, kv), "tenant/did:plc:a"); err != nil {
		t.Fatal(err)
	}
	if want := []string{"tenant/did:plc:a"}; !reflect.DeepEqual(kv.destroyed, want) {
		t.Errorf("destroyed = %v, want %v", kv.destroyed, want)
	}
}

// The root token reaches every mount, so the subtree check is what keeps a bad
// path from destroying something hilt does not own.
func TestDestroyHiltSecretRefusesAPathOutsideTheTenantSubtree(t *testing.T) {
	kv := &fakeHiltKV{}

	err := DestroyHiltSecret(context.Background(), newHiltKVClient(t, kv), "config/partner")
	if err == nil || !strings.Contains(err.Error(), "refusing") {
		t.Fatalf("DestroyHiltSecret() = %v, want a refusal", err)
	}
	if len(kv.destroyed) != 0 {
		t.Errorf("destroyed = %v, want none", kv.destroyed)
	}
}

// fakeHiltKV answers KV v2 list and metadata-delete requests on HiltMount,
// deriving folders from the secret paths it holds as OpenBao does.
type fakeHiltKV struct {
	secrets   map[string]bool
	destroyed []string
}

func (f *fakeHiltKV) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	prefix := "/v1/" + HiltMount + "/metadata/"
	if !strings.HasPrefix(r.URL.Path, prefix) {
		http.Error(w, "unexpected path "+r.URL.Path, http.StatusNotFound)
		return
	}
	path := strings.TrimPrefix(r.URL.Path, prefix)

	switch {
	case r.Method == "LIST" || (r.Method == "GET" && r.URL.Query().Get("list") == "true"):
		folder := strings.TrimSuffix(path, "/") + "/"
		keys := map[string]bool{}
		for secret := range f.secrets {
			rest, ok := strings.CutPrefix(secret, folder)
			if !ok {
				continue
			}
			if head, _, nested := strings.Cut(rest, "/"); nested {
				keys[head+"/"] = true
			} else {
				keys[rest] = true
			}
		}
		if len(keys) == 0 {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		var list []any
		for key := range keys {
			list = append(list, key)
		}
		writeJSON(w, map[string]any{"data": map[string]any{"keys": list}})

	case r.Method == "DELETE":
		f.destroyed = append(f.destroyed, path)
		delete(f.secrets, path)
		w.WriteHeader(http.StatusNoContent)

	default:
		http.Error(w, "unexpected request: "+r.Method+" "+r.URL.Path, http.StatusNotFound)
	}
}

func newHiltKVClient(t *testing.T, handler http.Handler) *api.Client {
	t.Helper()

	cfg := api.DefaultConfig()
	cfg.Address = "http://openbao.test"
	cfg.HttpClient = &http.Client{Transport: handlerTransport{handler: handler}}

	client, err := api.NewClient(cfg)
	if err != nil {
		t.Fatal(err)
	}
	client.SetToken("root-1")
	return client
}
