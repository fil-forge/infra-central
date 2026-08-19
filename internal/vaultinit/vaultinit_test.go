package vaultinit

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/openbao/openbao/api/v2"
)

func TestWaitForUnsealedReturnsWhenUnsealed(t *testing.T) {
	client := newClient(t, &fakeOpenBao{initialised: true})

	if err := WaitForUnsealed(context.Background(), client); err != nil {
		t.Fatalf("WaitForUnsealed() = %v, want nil", err)
	}
}

// An uninitialised server reports itself sealed; waiting for that to change
// would deadlock the first apply against a server behaving correctly.
func TestWaitForUnsealedReturnsWhenUninitialised(t *testing.T) {
	client := newClient(t, &fakeOpenBao{sealed: true})

	if err := WaitForUnsealed(context.Background(), client); err != nil {
		t.Fatalf("WaitForUnsealed() = %v, want nil", err)
	}
}

func TestWaitForUnsealedTimesOutNamingTheKMSSeal(t *testing.T) {
	client := newClient(t, &fakeOpenBao{initialised: true, sealed: true})

	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()

	err := WaitForUnsealed(ctx, client)
	if err == nil || !strings.Contains(err.Error(), "KMS seal") {
		t.Fatalf("WaitForUnsealed() = %v, want a timeout naming the KMS seal", err)
	}
}

func TestEnsureInitialisedSkipsAnInitialisedServer(t *testing.T) {
	client := newClient(t, &fakeOpenBao{initialised: true})

	result, err := EnsureInitialised(context.Background(), client)
	if err != nil {
		t.Fatal(err)
	}
	if want := (InitResult{Initialised: false}); !reflect.DeepEqual(result, want) {
		t.Errorf("EnsureInitialised() = %+v, want %+v", result, want)
	}
}

func TestEnsureInitialisedReturnsTheNewCredentials(t *testing.T) {
	client := newClient(t, &fakeOpenBao{})

	result, err := EnsureInitialised(context.Background(), client)
	if err != nil {
		t.Fatal(err)
	}
	want := InitResult{RootToken: "root-1", RecoveryKeys: []string{"rk-1"}, Initialised: true}
	if !reflect.DeepEqual(result, want) {
		t.Errorf("EnsureInitialised() = %+v, want %+v", result, want)
	}
}

func TestEnsureMountsCreatesBothMissingMounts(t *testing.T) {
	f := &fakeOpenBao{initialised: true}
	client := newClient(t, f)

	if err := EnsureMounts(context.Background(), client); err != nil {
		t.Fatal(err)
	}
	if want := []string{HiltMount, TransitMount}; !reflect.DeepEqual(f.mountedPaths, want) {
		t.Errorf("mounted paths = %v, want %v", f.mountedPaths, want)
	}
}

func TestEnsureMountsLeavesExistingMountsAlone(t *testing.T) {
	f := &fakeOpenBao{
		initialised: true,
		mounts:      map[string]string{HiltMount + "/": "kv", TransitMount + "/": "transit"},
	}
	client := newClient(t, f)

	if err := EnsureMounts(context.Background(), client); err != nil {
		t.Fatal(err)
	}
	if len(f.mountedPaths) != 0 {
		t.Errorf("mounted paths = %v, want none", f.mountedPaths)
	}
}

func TestEnsureHiltAppRoleReturnsTheRoleID(t *testing.T) {
	client := newClient(t, &fakeOpenBao{initialised: true})

	roleID, err := EnsureHiltAppRole(context.Background(), client, Config{})
	if err != nil {
		t.Fatal(err)
	}
	if roleID != "rid-1" {
		t.Errorf("EnsureHiltAppRole() = %q, want %q", roleID, "rid-1")
	}
}

// The CIDR bounds are the AppRole's network boundary; a role written without
// them would authenticate from anywhere.
func TestEnsureHiltAppRoleBindsBothCredentialsToTheCIDRs(t *testing.T) {
	f := &fakeOpenBao{initialised: true}
	client := newClient(t, f)

	_, err := EnsureHiltAppRole(context.Background(), client, Config{
		TokenBoundCIDRs: []string{"10.64.0.0/16"},
	})
	if err != nil {
		t.Fatal(err)
	}

	got := map[string]any{
		"token_bound_cidrs":     f.roleWrite["token_bound_cidrs"],
		"secret_id_bound_cidrs": f.roleWrite["secret_id_bound_cidrs"],
	}
	want := map[string]any{
		"token_bound_cidrs":     []any{"10.64.0.0/16"},
		"secret_id_bound_cidrs": []any{"10.64.0.0/16"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("role CIDR bounds = %v, want %v", got, want)
	}
}

func TestEnsureHiltAppRoleEnablesAppRoleAuthWhenMissing(t *testing.T) {
	f := &fakeOpenBao{initialised: true}
	client := newClient(t, f)

	if _, err := EnsureHiltAppRole(context.Background(), client, Config{}); err != nil {
		t.Fatal(err)
	}
	if want := []string{appRoleAuthMount}; !reflect.DeepEqual(f.enabledAuths, want) {
		t.Errorf("enabled auths = %v, want %v", f.enabledAuths, want)
	}
}

func TestEnsureHiltAppRoleSkipsEnablingExistingAuth(t *testing.T) {
	f := &fakeOpenBao{
		initialised: true,
		authMounts:  map[string]string{appRoleAuthMount + "/": "approle"},
	}
	client := newClient(t, f)

	if _, err := EnsureHiltAppRole(context.Background(), client, Config{}); err != nil {
		t.Fatal(err)
	}
	if len(f.enabledAuths) != 0 {
		t.Errorf("enabled auths = %v, want none", f.enabledAuths)
	}
}

func TestSecretIDValidAcceptsAKnownSecretID(t *testing.T) {
	client := newClient(t, &fakeOpenBao{initialised: true, secretIDKnown: true})

	if !SecretIDValid(context.Background(), client, "sid-1") {
		t.Error("SecretIDValid() = false, want true")
	}
}

func TestSecretIDValidRejectsAnUnknownSecretID(t *testing.T) {
	client := newClient(t, &fakeOpenBao{initialised: true})

	if SecretIDValid(context.Background(), client, "sid-stale") {
		t.Error("SecretIDValid() = true, want false")
	}
}

func TestIssueSecretIDReturnsTheMintedSecret(t *testing.T) {
	client := newClient(t, &fakeOpenBao{initialised: true})

	secretID, err := IssueSecretID(context.Background(), client)
	if err != nil {
		t.Fatal(err)
	}
	if secretID != "sid-1" {
		t.Errorf("IssueSecretID() = %q, want %q", secretID, "sid-1")
	}
}

func newClient(t *testing.T, f *fakeOpenBao) *api.Client {
	t.Helper()
	srv := httptest.NewServer(f)
	t.Cleanup(srv.Close)

	client, err := api.NewClient(&api.Config{Address: srv.URL})
	if err != nil {
		t.Fatal(err)
	}
	return client
}

// fakeOpenBao mimics the slice of the OpenBao HTTP API that vaultinit touches.
// State fields configure the scenario; recorded fields capture what the code
// under test asked the server to change.
type fakeOpenBao struct {
	initialised   bool
	sealed        bool
	mounts        map[string]string // path with trailing slash -> engine type
	authMounts    map[string]string
	secretIDKnown bool

	mountedPaths []string
	enabledAuths []string
	roleWrite    map[string]any
}

func (f *fakeOpenBao) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	key := r.Method + " " + r.URL.Path
	switch {
	case key == "GET /v1/sys/seal-status":
		writeJSON(w, map[string]any{"initialized": f.initialised, "sealed": f.sealed})

	case key == "GET /v1/sys/init":
		writeJSON(w, map[string]any{"initialized": f.initialised})

	case key == "PUT /v1/sys/init":
		f.initialised = true
		writeJSON(w, map[string]any{"root_token": "root-1", "recovery_keys_base64": []string{"rk-1"}})

	case key == "GET /v1/sys/mounts":
		data := map[string]any{}
		for path, engine := range f.mounts {
			data[path] = map[string]any{"type": engine}
		}
		writeJSON(w, map[string]any{"data": data})

	case r.Method == "POST" && strings.HasPrefix(r.URL.Path, "/v1/sys/mounts/"):
		f.mountedPaths = append(f.mountedPaths, strings.TrimPrefix(r.URL.Path, "/v1/sys/mounts/"))
		w.WriteHeader(http.StatusNoContent)

	case key == "PUT /v1/sys/policies/acl/hilt":
		w.WriteHeader(http.StatusNoContent)

	case key == "GET /v1/sys/auth":
		data := map[string]any{}
		for path, kind := range f.authMounts {
			data[path] = map[string]any{"type": kind}
		}
		writeJSON(w, map[string]any{"data": data})

	case r.Method == "POST" && strings.HasPrefix(r.URL.Path, "/v1/sys/auth/"):
		f.enabledAuths = append(f.enabledAuths, strings.TrimPrefix(r.URL.Path, "/v1/sys/auth/"))
		w.WriteHeader(http.StatusNoContent)

	case key == "PUT /v1/auth/approle/role/hilt":
		if err := json.NewDecoder(r.Body).Decode(&f.roleWrite); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		w.WriteHeader(http.StatusNoContent)

	case key == "GET /v1/auth/approle/role/hilt/role-id":
		writeJSON(w, map[string]any{"data": map[string]any{"role_id": "rid-1"}})

	case key == "PUT /v1/auth/approle/role/hilt/secret-id/lookup":
		if !f.secretIDKnown {
			// A stale secret_id looks up to an empty result, not an error.
			w.WriteHeader(http.StatusNoContent)
			return
		}
		writeJSON(w, map[string]any{"data": map[string]any{"creation_time": "2026-01-01T00:00:00Z"}})

	case key == "PUT /v1/auth/approle/role/hilt/secret-id":
		writeJSON(w, map[string]any{"data": map[string]any{"secret_id": "sid-1"}})

	default:
		http.Error(w, "unexpected request: "+key, http.StatusNotFound)
	}
}

func writeJSON(w http.ResponseWriter, body map[string]any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(body)
}
