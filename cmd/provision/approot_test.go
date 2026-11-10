package main

import (
	"context"
	"encoding/json"
	"net/http"
	"reflect"
	"strings"
	"testing"

	"github.com/fil-forge/infra-central/internal/vaultinit"
)

func TestPlanRootCredentials(t *testing.T) {
	cases := []struct {
		desc     string
		versions map[string]int
		want     RootCredentialsPlan
	}{
		{
			desc: "central holds no copy",
			want: RootCredentialsPlan{Region: "eu-central-3", Action: rootCredentialsActionStore},
		},
		{
			desc:     "central holds a copy",
			versions: map[string]int{"eu-central-3": 2},
			want:     RootCredentialsPlan{Region: "eu-central-3", Action: rootCredentialsActionReplace, StoredVersion: 2},
		},
	}
	for _, c := range cases {
		t.Run(c.desc, func(t *testing.T) {
			bao := &fakeRootStore{regions: []string{"eu-central-3"}, versions: c.versions}

			plan, err := planRootCredentials(context.Background(), newTokenClient(t, bao), "eu-central-3")
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(*plan, c.want) {
				t.Errorf("plan = %+v, want %+v", *plan, c.want)
			}
		})
	}
}

// Git decides which regions a stage knows, so a typo cannot leave credentials
// under a label nothing will ever retire.
func TestPlanRootCredentialsRefusesARegionWithNoTransitKey(t *testing.T) {
	bao := &fakeRootStore{}

	_, err := planRootCredentials(context.Background(), newTokenClient(t, bao), "eu-central-3")
	if err == nil || !strings.Contains(err.Error(), "appliance_regions") {
		t.Fatalf("planRootCredentials() = %v, want a refusal naming appliance_regions", err)
	}
}

func TestStoreRootCredentialsWritesBothValuesAndReturnsNeither(t *testing.T) {
	bao := &fakeRootStore{regions: []string{"eu-central-3"}}
	req := Request{Region: "eu-central-3", RootToken: "root-token-1", RecoveryKey: "recovery-key-1"}

	result, err := storeRootCredentials(context.Background(), newTokenClient(t, bao), req)
	if err != nil {
		t.Fatal(err)
	}
	if want := (RootCredentialsResult{Region: "eu-central-3", Version: 1}); *result != want {
		t.Errorf("result = %+v, want %+v", *result, want)
	}
	wantWritten := map[string]any{"root_token": "root-token-1", "recovery_key": "recovery-key-1"}
	if !reflect.DeepEqual(bao.written, wantWritten) {
		t.Errorf("written = %v, want %v", bao.written, wantWritten)
	}

	response, err := json.Marshal(Response{Phase: "appliance-root-store", RootCredentialsResult: result})
	if err != nil {
		t.Fatal(err)
	}
	for _, secret := range []string{req.RootToken, req.RecoveryKey} {
		if strings.Contains(string(response), secret) {
			t.Errorf("the response carries %q: %s", secret, response)
		}
	}
}

func TestStoreRootCredentialsRefusesAMissingValue(t *testing.T) {
	cases := []struct {
		desc string
		req  Request
	}{
		{desc: "no root token", req: Request{Region: "eu-central-3", RecoveryKey: "recovery-key-1"}},
		{desc: "no recovery key", req: Request{Region: "eu-central-3", RootToken: "root-token-1"}},
	}
	for _, c := range cases {
		t.Run(c.desc, func(t *testing.T) {
			bao := &fakeRootStore{regions: []string{"eu-central-3"}}

			if _, err := storeRootCredentials(context.Background(), newTokenClient(t, bao), c.req); err == nil {
				t.Fatal("storeRootCredentials() = nil, want a refusal")
			}
			if bao.written != nil {
				t.Errorf("written = %v, want nothing", bao.written)
			}
		})
	}
}

// fakeRootStore answers the transit-key read and the KV v2 requests the
// appliance-root-store phase makes.
type fakeRootStore struct {
	regions  []string       // regions with a transit key
	versions map[string]int // region -> stored version
	written  map[string]any
}

func (f *fakeRootStore) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	const created = "2026-11-10T00:00:00Z"
	mount := "/v1/" + vaultinit.ApplianceRootMount
	key, isKey := strings.CutPrefix(r.URL.Path, "/v1/transit/keys/"+vaultinit.AppliancePrefix)
	metadata, isMetadata := strings.CutPrefix(r.URL.Path, mount+"/metadata/")
	data, isData := strings.CutPrefix(r.URL.Path, mount+"/data/")

	respond := func(body map[string]any) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"data": body})
	}

	switch {
	case isKey && r.Method == "GET":
		for _, region := range f.regions {
			if region == key {
				respond(map[string]any{"name": vaultinit.ApplianceKeyName(region)})
				return
			}
		}
		w.WriteHeader(http.StatusNotFound)

	case isMetadata && r.Method == "GET":
		version, ok := f.versions[metadata]
		if !ok {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		respond(map[string]any{
			"current_version": version,
			"created_time":    created,
			"updated_time":    created,
			"versions":        map[string]any{},
		})

	case isData && r.Method == "PUT":
		var body struct {
			Data map[string]any `json:"data"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		if f.versions == nil {
			f.versions = map[string]int{}
		}
		f.written = body.Data
		f.versions[data]++
		respond(map[string]any{
			"version":       f.versions[data],
			"created_time":  created,
			"deletion_time": "",
			"destroyed":     false,
		})

	default:
		http.Error(w, "unexpected request: "+r.Method+" "+r.URL.Path, http.StatusNotFound)
	}
}
