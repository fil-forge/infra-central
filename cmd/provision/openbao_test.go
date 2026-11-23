package main

import (
	"net/http"
	"reflect"
	"strings"
	"testing"

	"github.com/openbao/openbao/api/v2"

	"github.com/fil-forge/infra-central/internal/vaultinit"
)

func TestNewOpenBaoClientSendsTheRequestIDOnEveryRequest(t *testing.T) {
	bao := &headerRecorder{}
	client := newRecordedOpenBaoClient(t, bao, "any-request")

	readAnyPath(t, client, "sys/mounts")
	readAnyPath(t, client, "sys/seal-status")

	if want := []string{"any-request", "any-request"}; !reflect.DeepEqual(bao.correlationIDs, want) {
		t.Errorf("%s values = %q, want %q", vaultinit.CorrelationHeader, bao.correlationIDs, want)
	}
}

// vaultinit clones the client to probe OpenBao and to unwrap tokens.
func TestNewOpenBaoClientSendsTheRequestIDFromAClone(t *testing.T) {
	bao := &headerRecorder{}
	clone, err := newRecordedOpenBaoClient(t, bao, "any-request").Clone()
	if err != nil {
		t.Fatal(err)
	}

	readAnyPath(t, clone, "sys/seal-status")

	if want := []string{"any-request"}; !reflect.DeepEqual(bao.correlationIDs, want) {
		t.Errorf("%s values = %q, want %q", vaultinit.CorrelationHeader, bao.correlationIDs, want)
	}
}

func TestNewOpenBaoClientSendsNoHeaderWithoutARequestID(t *testing.T) {
	bao := &headerRecorder{}
	client := newRecordedOpenBaoClient(t, bao, "")

	readAnyPath(t, client, "sys/mounts")

	if want := []string{headerAbsent}; !reflect.DeepEqual(bao.correlationIDs, want) {
		t.Errorf("%s values = %q, want %q", vaultinit.CorrelationHeader, bao.correlationIDs, want)
	}
}

func newRecordedOpenBaoClient(t *testing.T, handler http.Handler, requestID string) *api.Client {
	t.Helper()

	cfg := api.DefaultConfig()
	cfg.Address = "http://openbao.test"
	cfg.HttpClient = &http.Client{Transport: handlerTransport{handler: handler}}

	client, err := newOpenBaoClient(cfg, requestID)
	if err != nil {
		t.Fatal(err)
	}
	client.SetToken("any-token")
	return client
}

func readAnyPath(t *testing.T, client *api.Client, path string) {
	t.Helper()
	if _, err := client.Logical().Read(path); err != nil {
		t.Fatal(err)
	}
}

// headerAbsent is what headerRecorder records for a request that carried no
// correlation header, as opposed to an empty one.
const headerAbsent = "(absent)"

// headerRecorder answers every request with an empty secret and records the
// correlation header each one carried.
type headerRecorder struct {
	correlationIDs []string
}

func (h *headerRecorder) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	values := r.Header.Values(vaultinit.CorrelationHeader)
	switch len(values) {
	case 0:
		h.correlationIDs = append(h.correlationIDs, headerAbsent)
	default:
		h.correlationIDs = append(h.correlationIDs, strings.Join(values, ","))
	}
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write([]byte(`{"data":{}}`))
}
