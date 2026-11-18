package main

import (
	"context"
	"errors"
	"reflect"
	"slices"
	"strings"
	"testing"

	"github.com/fil-forge/infra-central/internal/secretstore"
	"github.com/fil-forge/infra-central/internal/vaultinit"
)

// PutIfChanged makes fakeKeys a credentialStore.
func (f *fakeKeys) PutIfChanged(ctx context.Context, service, name, value string) (secretstore.Secret, error) {
	f.values[service+"/"+name] = value
	return secretstore.Secret{Value: value, ARN: "arn:" + service + "/" + name}, nil
}

// Obvious fakes: nothing here is a credential.
const (
	fakeRootToken    = "fake-root-token"
	fakeRecoveryKeys = `["fake-recovery-key-1","fake-recovery-key-2"]`
	staleRootToken   = "fake-stale-root-token"
	staleRecoveryKey = `["fake-stale-recovery-key"]`
)

var freshInit = vaultinit.InitResult{
	Initialised:  true,
	RootToken:    fakeRootToken,
	RecoveryKeys: []string{"fake-recovery-key-1", "fake-recovery-key-2"},
}

var bothARNs = map[string]string{
	"root-token":    "arn:openbao/root-token",
	"recovery-keys": "arn:openbao/recovery-keys",
}

// credentialsOutcome is everything ensureOpenBaoCredentials can change or
// report, compared in one go.
type credentialsOutcome struct {
	Failed       bool
	RootToken    string
	ARNs         map[string]string
	DeleteLegacy bool
	Secrets      map[string]string
	SSM          map[string]string
}

func TestEnsureOpenBaoCredentials(t *testing.T) {
	testCases := []struct {
		name       string
		init       vaultinit.InitResult
		secrets    map[string]string
		ssm        map[string]string
		tokenValid tokenChecker
		wantResult credentialsOutcome
	}{
		{
			name:    "fresh initialisation stores both credentials",
			init:    freshInit,
			secrets: map[string]string{},
			ssm:     map[string]string{},
			wantResult: credentialsOutcome{
				RootToken: fakeRootToken,
				ARNs:      bothARNs,
				Secrets:   map[string]string{"openbao/root-token": fakeRootToken, "openbao/recovery-keys": fakeRecoveryKeys},
				SSM:       map[string]string{},
			},
		},
		{
			name:    "fresh initialisation overwrites stale secrets and deletes stale SSM copies at once",
			init:    freshInit,
			secrets: map[string]string{"openbao/root-token": staleRootToken, "openbao/recovery-keys": staleRecoveryKey},
			ssm:     map[string]string{"openbao/root-token": staleRootToken, "openbao/recovery-keys": staleRecoveryKey},
			wantResult: credentialsOutcome{
				RootToken: fakeRootToken,
				ARNs:      bothARNs,
				Secrets:   map[string]string{"openbao/root-token": fakeRootToken, "openbao/recovery-keys": fakeRecoveryKeys},
				SSM:       map[string]string{},
			},
		},
		{
			name:    "already initialised stage with both credentials only in SSM is migrated",
			secrets: map[string]string{},
			ssm:     map[string]string{"openbao/root-token": fakeRootToken, "openbao/recovery-keys": fakeRecoveryKeys},
			wantResult: credentialsOutcome{
				RootToken:    fakeRootToken,
				ARNs:         bothARNs,
				DeleteLegacy: true,
				Secrets:      map[string]string{"openbao/root-token": fakeRootToken, "openbao/recovery-keys": fakeRecoveryKeys},
				SSM:          map[string]string{"openbao/root-token": fakeRootToken, "openbao/recovery-keys": fakeRecoveryKeys},
			},
		},
		{
			name:    "a migration that stopped after the root token finishes with the recovery keys",
			secrets: map[string]string{"openbao/root-token": fakeRootToken},
			ssm:     map[string]string{"openbao/recovery-keys": fakeRecoveryKeys},
			wantResult: credentialsOutcome{
				RootToken:    fakeRootToken,
				ARNs:         bothARNs,
				DeleteLegacy: true,
				Secrets:      map[string]string{"openbao/root-token": fakeRootToken, "openbao/recovery-keys": fakeRecoveryKeys},
				SSM:          map[string]string{"openbao/recovery-keys": fakeRecoveryKeys},
			},
		},
		{
			name:    "a migration that stopped before deleting the SSM copies marks them for deletion",
			secrets: map[string]string{"openbao/root-token": fakeRootToken, "openbao/recovery-keys": fakeRecoveryKeys},
			ssm:     map[string]string{"openbao/root-token": fakeRootToken, "openbao/recovery-keys": fakeRecoveryKeys},
			wantResult: credentialsOutcome{
				RootToken:    fakeRootToken,
				ARNs:         bothARNs,
				DeleteLegacy: true,
				Secrets:      map[string]string{"openbao/root-token": fakeRootToken, "openbao/recovery-keys": fakeRecoveryKeys},
				SSM:          map[string]string{"openbao/root-token": fakeRootToken, "openbao/recovery-keys": fakeRecoveryKeys},
			},
		},
		{
			name:    "a migrated stage reads both credentials from Secrets Manager",
			secrets: map[string]string{"openbao/root-token": fakeRootToken, "openbao/recovery-keys": fakeRecoveryKeys},
			ssm:     map[string]string{},
			wantResult: credentialsOutcome{
				RootToken: fakeRootToken,
				ARNs:      bothARNs,
				Secrets:   map[string]string{"openbao/root-token": fakeRootToken, "openbao/recovery-keys": fakeRecoveryKeys},
				SSM:       map[string]string{},
			},
		},
		{
			name:    "root tokens that differ fail when OpenBao accepts neither",
			secrets: map[string]string{"openbao/root-token": fakeRootToken, "openbao/recovery-keys": fakeRecoveryKeys},
			ssm:     map[string]string{"openbao/root-token": staleRootToken},
			wantResult: credentialsOutcome{
				Failed:  true,
				Secrets: map[string]string{"openbao/root-token": fakeRootToken, "openbao/recovery-keys": fakeRecoveryKeys},
				SSM:     map[string]string{"openbao/root-token": staleRootToken},
			},
		},
		{
			name:    "recovery keys that differ between the stores fail",
			secrets: map[string]string{"openbao/root-token": fakeRootToken, "openbao/recovery-keys": fakeRecoveryKeys},
			ssm:     map[string]string{"openbao/recovery-keys": staleRecoveryKey},
			wantResult: credentialsOutcome{
				Failed:  true,
				Secrets: map[string]string{"openbao/root-token": fakeRootToken, "openbao/recovery-keys": fakeRecoveryKeys},
				SSM:     map[string]string{"openbao/recovery-keys": staleRecoveryKey},
			},
		},
		{
			name:       "SSM copies whose root token OpenBao refuses are deleted when it accepts the Secrets Manager one",
			secrets:    map[string]string{"openbao/root-token": fakeRootToken, "openbao/recovery-keys": fakeRecoveryKeys},
			ssm:        map[string]string{"openbao/root-token": staleRootToken, "openbao/recovery-keys": staleRecoveryKey},
			tokenValid: liveTokens(fakeRootToken),
			wantResult: credentialsOutcome{
				RootToken: fakeRootToken,
				ARNs:      bothARNs,
				Secrets:   map[string]string{"openbao/root-token": fakeRootToken, "openbao/recovery-keys": fakeRecoveryKeys},
				SSM:       map[string]string{},
			},
		},
		{
			name:       "root tokens that differ fail when OpenBao accepts only the SSM one",
			secrets:    map[string]string{"openbao/root-token": fakeRootToken, "openbao/recovery-keys": fakeRecoveryKeys},
			ssm:        map[string]string{"openbao/root-token": staleRootToken},
			tokenValid: liveTokens(staleRootToken),
			wantResult: credentialsOutcome{
				Failed:  true,
				Secrets: map[string]string{"openbao/root-token": fakeRootToken, "openbao/recovery-keys": fakeRecoveryKeys},
				SSM:     map[string]string{"openbao/root-token": staleRootToken},
			},
		},
		{
			name:       "root tokens that differ fail when OpenBao accepts both",
			secrets:    map[string]string{"openbao/root-token": fakeRootToken, "openbao/recovery-keys": fakeRecoveryKeys},
			ssm:        map[string]string{"openbao/root-token": staleRootToken},
			tokenValid: liveTokens(fakeRootToken, staleRootToken),
			wantResult: credentialsOutcome{
				Failed:  true,
				Secrets: map[string]string{"openbao/root-token": fakeRootToken, "openbao/recovery-keys": fakeRecoveryKeys},
				SSM:     map[string]string{"openbao/root-token": staleRootToken},
			},
		},
		{
			name:       "root tokens that differ fail when OpenBao cannot be asked",
			secrets:    map[string]string{"openbao/root-token": fakeRootToken, "openbao/recovery-keys": fakeRecoveryKeys},
			ssm:        map[string]string{"openbao/root-token": staleRootToken},
			tokenValid: unreachableOpenBao,
			wantResult: credentialsOutcome{
				Failed:  true,
				Secrets: map[string]string{"openbao/root-token": fakeRootToken, "openbao/recovery-keys": fakeRecoveryKeys},
				SSM:     map[string]string{"openbao/root-token": staleRootToken},
			},
		},
		{
			name:    "a root token missing from both stores fails",
			secrets: map[string]string{"openbao/recovery-keys": fakeRecoveryKeys},
			ssm:     map[string]string{},
			wantResult: credentialsOutcome{
				Failed:  true,
				Secrets: map[string]string{"openbao/recovery-keys": fakeRecoveryKeys},
				SSM:     map[string]string{},
			},
		},
		{
			name:    "recovery keys missing from both stores fail",
			secrets: map[string]string{},
			ssm:     map[string]string{"openbao/root-token": fakeRootToken},
			wantResult: credentialsOutcome{
				Failed:  true,
				Secrets: map[string]string{"openbao/root-token": fakeRootToken},
				SSM:     map[string]string{"openbao/root-token": fakeRootToken},
			},
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			keys := &fakeKeys{values: tc.secrets}
			legacy := &fakeLegacy{secrets: tc.ssm, public: map[string]string{}}

			tokenValid := tc.tokenValid
			if tokenValid == nil {
				tokenValid = liveTokens()
			}

			creds, err := ensureOpenBaoCredentials(context.Background(), keys, legacy, tokenValid, tc.init)

			got := credentialsOutcome{
				Failed:       err != nil,
				RootToken:    creds.rootToken,
				ARNs:         creds.arns,
				DeleteLegacy: creds.deleteLegacy,
				Secrets:      keys.values,
				SSM:          legacy.secrets,
			}
			if !reflect.DeepEqual(got, tc.wantResult) {
				t.Errorf("ensureOpenBaoCredentials() outcome = %+v, want %+v (err = %v)", got, tc.wantResult, err)
			}
		})
	}
}

func TestEnsureOpenBaoCredentialsNeverPutsACredentialInAnError(t *testing.T) {
	testCases := []struct {
		name    string
		secrets map[string]string
		ssm     map[string]string
	}{
		{
			name:    "root token differs",
			secrets: map[string]string{"openbao/root-token": fakeRootToken},
			ssm:     map[string]string{"openbao/root-token": staleRootToken},
		},
		{
			name:    "recovery keys differ",
			secrets: map[string]string{"openbao/root-token": fakeRootToken, "openbao/recovery-keys": fakeRecoveryKeys},
			ssm:     map[string]string{"openbao/recovery-keys": staleRecoveryKey},
		},
		{
			name:    "recovery keys missing",
			secrets: map[string]string{"openbao/root-token": fakeRootToken},
			ssm:     map[string]string{},
		},
	}
	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			keys := &fakeKeys{values: tc.secrets}
			legacy := &fakeLegacy{secrets: tc.ssm, public: map[string]string{}}

			_, err := ensureOpenBaoCredentials(context.Background(), keys, legacy, liveTokens(), vaultinit.InitResult{})
			if err == nil || strings.Contains(err.Error(), "fake-") {
				t.Errorf("ensureOpenBaoCredentials() error = %v, want an error naming no credential", err)
			}
		})
	}
}

func TestReplicateOpenBaoCredentials(t *testing.T) {
	testCases := []struct {
		name      string
		region    string
		existing  map[string]bool
		wantAsked []string
		wantResp  Response
	}{
		{
			name:   "replica requested for both, recovery keys first, then waits for each",
			region: "eu-central-1",
			wantAsked: []string{
				"replicate arn:openbao/recovery-keys -> eu-central-1",
				"replicate arn:openbao/root-token -> eu-central-1",
				"wait arn:openbao/recovery-keys -> eu-central-1",
				"wait arn:openbao/root-token -> eu-central-1",
			},
			wantResp: Response{
				BackupReplicaRegion: "eu-central-1",
				Replicated:          []string{"forge-central/test/openbao/recovery-keys", "forge-central/test/openbao/root-token"},
			},
		},
		{
			name:     "existing replicas are waited for and not reported",
			region:   "eu-central-1",
			existing: map[string]bool{"arn:openbao/recovery-keys": true, "arn:openbao/root-token": true},
			wantAsked: []string{
				"replicate arn:openbao/recovery-keys -> eu-central-1",
				"replicate arn:openbao/root-token -> eu-central-1",
				"wait arn:openbao/recovery-keys -> eu-central-1",
				"wait arn:openbao/root-token -> eu-central-1",
			},
			wantResp: Response{BackupReplicaRegion: "eu-central-1"},
		},
		{
			name:     "replica region unset asks for nothing",
			region:   "",
			wantResp: Response{},
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			keys := &fakeReplicator{existing: tc.existing}
			resp := &Response{}

			err := replicateOpenBaoCredentials(context.Background(), keys, tc.region, bothARNs, resp)

			type outcome struct {
				Failed bool
				Asked  []string
				Resp   Response
			}
			got := outcome{Failed: err != nil, Asked: keys.asked, Resp: *resp}
			want := outcome{Asked: tc.wantAsked, Resp: tc.wantResp}
			if !reflect.DeepEqual(got, want) {
				t.Errorf("replicateOpenBaoCredentials() outcome = %+v, want %+v (err = %v)", got, want, err)
			}
		})
	}
}

func TestOpenBaoRootToken(t *testing.T) {
	testCases := []struct {
		name      string
		secrets   map[string]string
		ssm       map[string]string
		wantToken string
		wantErr   bool
	}{
		{
			name:      "Secrets Manager wins over SSM",
			secrets:   map[string]string{"openbao/root-token": fakeRootToken},
			ssm:       map[string]string{"openbao/root-token": staleRootToken},
			wantToken: fakeRootToken,
		},
		{
			name:      "SSM is read when Secrets Manager has no root token",
			secrets:   map[string]string{},
			ssm:       map[string]string{"openbao/root-token": fakeRootToken},
			wantToken: fakeRootToken,
		},
		{
			name:    "a root token in neither store fails",
			secrets: map[string]string{},
			ssm:     map[string]string{},
			wantErr: true,
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			keys := &fakeKeys{values: tc.secrets}
			legacy := &fakeLegacy{secrets: tc.ssm, public: map[string]string{}}

			token, err := openBaoRootToken(context.Background(), keys, legacy)

			type outcome struct {
				Token  string
				Failed bool
			}
			if got, want := (outcome{token, err != nil}), (outcome{tc.wantToken, tc.wantErr}); got != want {
				t.Errorf("openBaoRootToken() = %+v, want %+v (err = %v)", got, want, err)
			}
		})
	}
}

func TestEnsureOpenBaoCredentialsRerunAfterAFailedSSMDeleteSucceeds(t *testing.T) {
	keys := &fakeKeys{values: map[string]string{"openbao/root-token": staleRootToken, "openbao/recovery-keys": staleRecoveryKey}}
	legacy := &fakeLegacy{
		secrets:   map[string]string{"openbao/root-token": staleRootToken, "openbao/recovery-keys": staleRecoveryKey},
		public:    map[string]string{},
		deleteErr: errors.New("fake transient SSM failure"),
	}
	if _, err := ensureOpenBaoCredentials(context.Background(), keys, legacy, liveTokens(), freshInit); err == nil {
		t.Fatal("fresh initialisation succeeded although deleting the SSM copies failed")
	}

	// OpenBao now reports itself initialised and accepts only the new token.
	legacy.deleteErr = nil
	creds, err := ensureOpenBaoCredentials(context.Background(), keys, legacy, liveTokens(fakeRootToken), vaultinit.InitResult{})

	got := credentialsOutcome{
		Failed:       err != nil,
		RootToken:    creds.rootToken,
		ARNs:         creds.arns,
		DeleteLegacy: creds.deleteLegacy,
		Secrets:      keys.values,
		SSM:          legacy.secrets,
	}
	want := credentialsOutcome{
		RootToken: fakeRootToken,
		ARNs:      bothARNs,
		Secrets:   map[string]string{"openbao/root-token": fakeRootToken, "openbao/recovery-keys": fakeRecoveryKeys},
		SSM:       map[string]string{},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("rerun outcome = %+v, want %+v (err = %v)", got, want, err)
	}
}

// liveTokens stands in for OpenBao accepting exactly the given tokens.
func liveTokens(tokens ...string) tokenChecker {
	return func(ctx context.Context, token string) (bool, error) {
		return slices.Contains(tokens, token), nil
	}
}

func unreachableOpenBao(ctx context.Context, token string) (bool, error) {
	return false, errors.New("fake: openbao unreachable")
}
