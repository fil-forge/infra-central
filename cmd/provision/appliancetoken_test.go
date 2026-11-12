package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"

	"github.com/openbao/openbao/api/v2"
)

// A second live token for one node is the state minting must never reach, so
// what it does when a region already has an accessor on record is worth
// pinning.
func TestDecideTokenAction(t *testing.T) {
	cases := []struct {
		desc      string
		tokenLive bool
		reissue   bool
		want      string
	}{
		{
			desc: "the recorded token has lapsed",
			want: tokenActionMint,
		},
		{
			desc:    "the recorded token has lapsed and reissue was asked for anyway",
			reissue: true,
			want:    tokenActionMint,
		},
		{
			desc:      "the recorded token is live",
			tokenLive: true,
			want:      tokenActionSkip,
		},
		{
			desc:      "the recorded token is live and reissue was asked for",
			tokenLive: true,
			reissue:   true,
			want:      tokenActionReissue,
		},
	}

	for _, c := range cases {
		t.Run(c.desc, func(t *testing.T) {
			if got := decideTokenAction(c.tokenLive, c.reissue); got != c.want {
				t.Errorf("decideTokenAction(%v, %v) = %q, want %q", c.tokenLive, c.reissue, got, c.want)
			}
		})
	}
}

// A typo in a duration is caught while nothing has been changed yet, because the
// alternative is discovering it halfway through a reissue.
func TestValidateTokenDurations(t *testing.T) {
	cases := []struct {
		desc string
		plan *TokenPlan
		want string
	}{
		{
			desc: "both durations are the defaults",
			plan: &TokenPlan{Period: defaultTokenPeriod, WrapTTL: defaultWrapTTL},
		},
		{
			desc: "a period in days, which openbao accepts and time.ParseDuration does not",
			plan: &TokenPlan{Period: "3d", WrapTTL: defaultWrapTTL},
		},
		{
			desc: "the period is not a duration",
			plan: &TokenPlan{Period: "nope", WrapTTL: defaultWrapTTL},
			want: "--period",
		},
		{
			desc: "the wrap TTL is not a duration",
			plan: &TokenPlan{Period: defaultTokenPeriod, WrapTTL: "nope"},
			want: "--wrap-ttl",
		},
	}

	for _, c := range cases {
		t.Run(c.desc, func(t *testing.T) {
			err := validateTokenDurations(c.plan)
			switch {
			case c.want == "" && err != nil:
				t.Errorf("validateTokenDurations() = %v, want nil", err)
			case c.want != "" && (err == nil || !strings.Contains(err.Error(), c.want)):
				t.Errorf("validateTokenDurations() = %v, want an error naming %s", err, c.want)
			}
		})
	}
}

// A token whose accessor was never recorded is a token nothing can revoke, so a
// failed write has to take the token with it.
func TestRecordMintedAccessorRevokesTheTokenWhenTheWriteFails(t *testing.T) {
	bao := &fakeTokenStore{}
	client := newTokenClient(t, bao)

	err := recordMintedAccessor(context.Background(), client, failingRecorder{}, "appliance/us-east-9", "acc-1")
	if err == nil {
		t.Fatal("recordMintedAccessor() = nil, want the write error")
	}
	if want := []string{"acc-1"}; !reflect.DeepEqual(bao.revoked, want) {
		t.Errorf("revoked accessors = %v, want %v", bao.revoked, want)
	}
}

// An operator who has to finish the revocation by hand needs the accessor.
func TestRecordMintedAccessorNamesTheAccessorWhenRevokingAlsoFails(t *testing.T) {
	client := newTokenClient(t, &fakeTokenStore{revokeStatus: http.StatusForbidden})

	err := recordMintedAccessor(context.Background(), client, failingRecorder{}, "appliance/us-east-9", "acc-1")
	if err == nil || !strings.Contains(err.Error(), "acc-1") {
		t.Fatalf("recordMintedAccessor() = %v, want an error naming accessor acc-1", err)
	}
}

func TestRecordMintedAccessorKeepsTheTokenWhenTheWriteSucceeds(t *testing.T) {
	bao := &fakeTokenStore{}
	client := newTokenClient(t, bao)

	if err := recordMintedAccessor(context.Background(), client, recordingRecorder{}, "appliance/us-east-9", "acc-1"); err != nil {
		t.Fatal(err)
	}
	if len(bao.revoked) != 0 {
		t.Errorf("revoked accessors = %v, want none", bao.revoked)
	}
}

type failingRecorder struct{}

func (failingRecorder) PutPublic(context.Context, string, string, string) error {
	return errors.New("ssm is unavailable")
}

type recordingRecorder struct{}

func (recordingRecorder) PutPublic(context.Context, string, string, string) error { return nil }

// fakeTokenStore answers the one OpenBao endpoint these tests reach.
type fakeTokenStore struct {
	revoked      []string
	revokeStatus int
}

func (f *fakeTokenStore) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/v1/auth/token/revoke-accessor" {
		http.Error(w, "unexpected path "+r.URL.Path, http.StatusNotFound)
		return
	}
	if f.revokeStatus != 0 {
		w.WriteHeader(f.revokeStatus)
		_, _ = w.Write([]byte(`{"errors":["permission denied"]}`))
		return
	}

	var body struct {
		Accessor string `json:"accessor"`
	}
	_ = json.NewDecoder(r.Body).Decode(&body)
	f.revoked = append(f.revoked, body.Accessor)
	w.WriteHeader(http.StatusNoContent)
}

func newTokenClient(t *testing.T, handler http.Handler) *api.Client {
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

// The mint's dry run reports the transit key's versions so an operator can
// confirm that every retained appliance snapshot still restores.
func TestTransitKeyVersionsReadsBothVersions(t *testing.T) {
	data := map[string]any{
		"latest_version":         json.Number("3"),
		"min_decryption_version": json.Number("2"),
	}

	latest, minDecryption, err := transitKeyVersions(data)
	if err != nil || latest != 3 || minDecryption != 2 {
		t.Errorf("transitKeyVersions = (%d, %d, %v), want (3, 2, nil)", latest, minDecryption, err)
	}
}

func TestTransitKeyVersionsRejectsAnUnreadableField(t *testing.T) {
	cases := []struct {
		desc string
		data map[string]any
		want string
	}{
		{
			desc: "latest_version is missing",
			data: map[string]any{"min_decryption_version": json.Number("1")},
			want: "latest_version is <nil>, not a number",
		},
		{
			// A float64 is what a client without UseNumber would hand back.
			desc: "min_decryption_version is not a json.Number",
			data: map[string]any{"latest_version": json.Number("1"), "min_decryption_version": 1.0},
			want: "min_decryption_version is 1, not a number",
		},
		{
			desc: "min_decryption_version is not an integer",
			data: map[string]any{"latest_version": json.Number("1"), "min_decryption_version": json.Number("1.5")},
			want: "min_decryption_version is 1.5, not an integer",
		},
	}

	for _, c := range cases {
		t.Run(c.desc, func(t *testing.T) {
			_, _, err := transitKeyVersions(c.data)
			if err == nil || err.Error() != c.want {
				t.Errorf("transitKeyVersions error = %v, want %q", err, c.want)
			}
		})
	}
}
