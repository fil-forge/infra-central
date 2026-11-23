package vaultinit

import (
	"context"
	"encoding/json"
	"net/http"
	"reflect"
	"strings"
	"testing"

	"github.com/openbao/openbao/api/v2"
)

func TestEnsureCorrelationHeaderAuditedRegistersTheHeaderUnhashed(t *testing.T) {
	bao := &auditConfigRecorder{}

	if err := EnsureCorrelationHeaderAudited(context.Background(), newHandlerClient(t, bao)); err != nil {
		t.Fatal(err)
	}

	want := []recordedWrite{{
		Method: "PUT",
		Path:   "/v1/sys/config/auditing/request-headers/x-correlation-id",
		Body:   map[string]any{"hmac": false},
	}}
	if !reflect.DeepEqual(bao.writes, want) {
		t.Errorf("writes = %+v, want %+v", bao.writes, want)
	}
}

func TestEnsureCorrelationHeaderAuditedFailsWhenOpenBaoRefuses(t *testing.T) {
	bao := &auditConfigRecorder{refuse: true}

	err := EnsureCorrelationHeaderAudited(context.Background(), newHandlerClient(t, bao))
	if err == nil || !strings.Contains(err.Error(), CorrelationHeader) {
		t.Fatalf("EnsureCorrelationHeaderAudited() = %v, want an error naming %s", err, CorrelationHeader)
	}
}

func newHandlerClient(t *testing.T, handler http.Handler) *api.Client {
	t.Helper()

	cfg := api.DefaultConfig()
	cfg.Address = "http://openbao.test"
	cfg.HttpClient = &http.Client{Transport: handlerTransport{handler: handler}}

	client, err := api.NewClient(cfg)
	if err != nil {
		t.Fatal(err)
	}
	client.SetToken("any-token")
	return client
}

type recordedWrite struct {
	Method string
	Path   string
	Body   map[string]any
}

// auditConfigRecorder records every write and answers it as OpenBao does a
// successful config write, with 204 and no body, or refuses it as OpenBao
// refuses a token without sudo.
type auditConfigRecorder struct {
	refuse bool
	writes []recordedWrite
}

func (a *auditConfigRecorder) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	var body map[string]any
	_ = json.NewDecoder(r.Body).Decode(&body)
	a.writes = append(a.writes, recordedWrite{Method: r.Method, Path: r.URL.Path, Body: body})

	if a.refuse {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusForbidden)
		_, _ = w.Write([]byte(`{"errors":["permission denied"]}`))
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
