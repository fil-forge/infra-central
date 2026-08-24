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

// newClient hands the fake to the real OpenBao client through an in-process
// transport.
//
// Everything worth exercising still is: the client builds the URL, sets its
// headers, serialises the body and parses the response exactly as it would over
// a socket. What is skipped is only the socket, which no assertion here depends
// on and which needs a listener the test does not otherwise need.
func newClient(t *testing.T, f *fakeOpenBao) *api.Client {
	t.Helper()

	cfg := api.DefaultConfig()
	cfg.Address = "http://openbao.test"
	cfg.HttpClient = &http.Client{Transport: handlerTransport{handler: f}}

	client, err := api.NewClient(cfg)
	if err != nil {
		t.Fatal(err)
	}
	return client
}

// handlerTransport answers each request from a handler rather than a connection.
type handlerTransport struct {
	handler http.Handler
}

func (t handlerTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	recorder := httptest.NewRecorder()
	t.handler.ServeHTTP(recorder, req)

	resp := recorder.Result()
	// A response the client reads status and body from needs its request back;
	// the api client logs the URL on an error path.
	resp.Request = req
	return resp, nil
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
	transitKeys   map[string]bool // key name -> exists
	accessorKnown bool
	refuseToWrap  bool

	mountedPaths     []string
	enabledAuths     []string
	roleWrite        map[string]any
	policies         map[string]string
	deletedPolicies  []string
	deletionAllowed  map[string]bool
	tokenRoles       map[string]map[string]any
	revokedAccessors []string
	wrapTTLSeen      string
	tokenCreateBody  map[string]any
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

	case r.Method == "PUT" && strings.HasPrefix(r.URL.Path, "/v1/sys/policies/acl/"):
		var body struct {
			Policy string `json:"policy"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		if f.policies == nil {
			f.policies = map[string]string{}
		}
		f.policies[strings.TrimPrefix(r.URL.Path, "/v1/sys/policies/acl/")] = body.Policy
		w.WriteHeader(http.StatusNoContent)

	case r.Method == "DELETE" && strings.HasPrefix(r.URL.Path, "/v1/sys/policies/acl/"):
		name := strings.TrimPrefix(r.URL.Path, "/v1/sys/policies/acl/")
		f.deletedPolicies = append(f.deletedPolicies, name)
		delete(f.policies, name)
		w.WriteHeader(http.StatusNoContent)

	case key == "LIST /v1/transit/keys" || (r.Method == "GET" && r.URL.Path == "/v1/transit/keys" && r.URL.Query().Get("list") == "true"):
		var names []string
		for name := range f.transitKeys {
			names = append(names, name)
		}
		if len(names) == 0 {
			// An empty transit mount has nothing to list, which the API
			// reports as a 404 rather than an empty array.
			w.WriteHeader(http.StatusNotFound)
			return
		}
		writeJSON(w, map[string]any{"data": map[string]any{"keys": names}})

	case r.Method == "PUT" && strings.HasSuffix(r.URL.Path, "/config") && strings.HasPrefix(r.URL.Path, "/v1/transit/keys/"):
		name := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/v1/transit/keys/"), "/config")
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		if f.deletionAllowed == nil {
			f.deletionAllowed = map[string]bool{}
		}
		if allowed, ok := body["deletion_allowed"].(bool); ok {
			f.deletionAllowed[name] = allowed
		}
		w.WriteHeader(http.StatusNoContent)

	case r.Method == "GET" && strings.HasPrefix(r.URL.Path, "/v1/transit/keys/"):
		name := strings.TrimPrefix(r.URL.Path, "/v1/transit/keys/")
		if !f.transitKeys[name] {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		writeJSON(w, map[string]any{"data": map[string]any{"name": name}})

	case r.Method == "PUT" && strings.HasPrefix(r.URL.Path, "/v1/transit/keys/"):
		if f.transitKeys == nil {
			f.transitKeys = map[string]bool{}
		}
		f.transitKeys[strings.TrimPrefix(r.URL.Path, "/v1/transit/keys/")] = true
		w.WriteHeader(http.StatusNoContent)

	case r.Method == "DELETE" && strings.HasPrefix(r.URL.Path, "/v1/transit/keys/"):
		name := strings.TrimPrefix(r.URL.Path, "/v1/transit/keys/")
		if !f.deletionAllowed[name] {
			http.Error(w, "deletion is not allowed for this key", http.StatusBadRequest)
			return
		}
		delete(f.transitKeys, name)
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

	case r.Method == "PUT" && strings.HasPrefix(r.URL.Path, "/v1/auth/token/roles/"):
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		if f.tokenRoles == nil {
			f.tokenRoles = map[string]map[string]any{}
		}
		f.tokenRoles[strings.TrimPrefix(r.URL.Path, "/v1/auth/token/roles/")] = body
		w.WriteHeader(http.StatusNoContent)

	case r.Method == "DELETE" && strings.HasPrefix(r.URL.Path, "/v1/auth/token/roles/"):
		delete(f.tokenRoles, strings.TrimPrefix(r.URL.Path, "/v1/auth/token/roles/"))
		w.WriteHeader(http.StatusNoContent)

	case r.Method == "PUT" && strings.HasPrefix(r.URL.Path, "/v1/auth/token/create/"):
		if err := json.NewDecoder(r.Body).Decode(&f.tokenCreateBody); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		// Wrapping is requested through a header, and the response shape
		// changes completely when it is honoured: the token moves into
		// wrap_info and auth is absent.
		f.wrapTTLSeen = r.Header.Get("X-Vault-Wrap-TTL")
		if f.wrapTTLSeen == "" || f.refuseToWrap {
			writeJSON(w, map[string]any{"auth": map[string]any{"client_token": "plain-1", "accessor": "acc-1"}})
			return
		}
		writeJSON(w, map[string]any{
			"wrap_info": map[string]any{
				"token":            "wrap-1",
				"accessor":         "wrap-acc-1",
				"wrapped_accessor": "acc-1",
				"ttl":              86400,
			},
		})

	case key == "POST /v1/auth/token/lookup-accessor":
		if !f.accessorKnown {
			// A lapsed accessor is reported as a 400 naming it, not a 404.
			http.Error(w, `{"errors":["invalid accessor"]}`, http.StatusBadRequest)
			return
		}
		writeJSON(w, map[string]any{"data": map[string]any{"accessor": "acc-1", "policies": []string{"x"}}})

	case key == "POST /v1/auth/token/revoke-accessor":
		if !f.accessorKnown {
			http.Error(w, `{"errors":["invalid accessor"]}`, http.StatusBadRequest)
			return
		}
		var body struct {
			Accessor string `json:"accessor"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		f.revokedAccessors = append(f.revokedAccessors, body.Accessor)
		w.WriteHeader(http.StatusNoContent)

	default:
		http.Error(w, "unexpected request: "+key, http.StatusNotFound)
	}
}

func writeJSON(w http.ResponseWriter, body map[string]any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(body)
}
