package dbinit

import (
	"context"
	"strings"
	"testing"
)

// The password is interpolated into ALTER ROLE rather than bound, so the
// hex-only guard is the whole defence. These inputs must be refused before the
// connection is ever touched, which is why a nil connection is safe here.
func TestEnsureRejectsNonHexPasswords(t *testing.T) {
	rejected := map[string]string{
		"a quote that would close the literal": "abc'def",
		"a backslash":                          `abc\def`,
		"a statement separator":                "abc'; DROP DATABASE sprue; --",
		"uppercase hex":                        "ABCDEF",
		"an empty password":                    "",
	}

	for name, password := range rejected {
		t.Run(name, func(t *testing.T) {
			err := Ensure(context.Background(), nil, []Database{{Name: "sprue", Password: password}})
			if err == nil {
				t.Fatal("Ensure accepted a password it should have refused")
			}
			if !strings.Contains(err.Error(), "hex-only") {
				t.Errorf("error = %q, want it to name the hex-only guard", err)
			}
		})
	}
}

// Every value of a login role is interpolated too, so the same guards apply
// to it, and none may be skipped because the owner's values are clean.
func TestEnsureRejectsUnsafeLoginRoles(t *testing.T) {
	rejected := []struct {
		name    string
		role    Role
		wantErr string
	}{
		{
			name:    "a non-hex password",
			role:    Role{Name: "pandora_storage_server", Password: "abc'def"},
			wantErr: "hex-only",
		},
		{
			name: "a setting dbinit does not apply",
			role: Role{Name: "pandora_storage_server", Password: "abc123",
				Settings: []Setting{{Name: "search_path", Value: "15s"}}},
			wantErr: "not one dbinit applies",
		},
		{
			name: "a value that would close the literal",
			role: Role{Name: "pandora_storage_server", Password: "abc123",
				Settings: []Setting{{Name: "statement_timeout", Value: "15s'; DROP ROLE pandora; --"}}},
			wantErr: "not a duration",
		},
		{
			name: "a value with a space",
			role: Role{Name: "pandora_storage_server", Password: "abc123",
				Settings: []Setting{{Name: "statement_timeout", Value: "15 s"}}},
			wantErr: "not a duration",
		},
		{
			name: "an empty value",
			role: Role{Name: "pandora_storage_server", Password: "abc123",
				Settings: []Setting{{Name: "statement_timeout", Value: ""}}},
			wantErr: "not a duration",
		},
	}

	for _, tc := range rejected {
		t.Run(tc.name, func(t *testing.T) {
			db := Database{Name: "pandora", Password: "abc123", LoginRoles: []Role{tc.role}}
			err := Ensure(context.Background(), nil, []Database{db})
			if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
				t.Errorf("Ensure() error = %v, want it to contain %q", err, tc.wantErr)
			}
		})
	}
}

// Validation runs before any statement, so a bad second database cannot leave
// the first one half done. A nil connection panics if Ensure reaches it.
func TestEnsureValidatesEveryDatabaseBeforeConnecting(t *testing.T) {
	databases := []Database{
		{Name: "sprue", Password: "abc123"},
		{Name: "hilt", Password: "not hex"},
	}

	err := Ensure(context.Background(), nil, databases)
	if err == nil || !strings.Contains(err.Error(), "hex-only") {
		t.Errorf("Ensure() error = %v, want the hex-only guard to refuse hilt", err)
	}
}

func TestDSN(t *testing.T) {
	cases := []struct {
		name     string
		database string
		username string
		sslmode  SSLMode
		want     string
	}{
		{
			name:     "a service owning its database, with TLS required",
			database: "sprue",
			username: "sprue",
			sslmode:  SSLRequire,
			want:     "postgres://sprue:abc123@db.internal:5432/sprue?sslmode=require",
		},
		{
			name:     "a login role on another role's database, verifying the server",
			database: "pandora",
			username: "pandora_storage_server",
			sslmode:  SSLVerifyFull,
			want:     "postgres://pandora_storage_server:abc123@db.internal:5432/pandora?sslmode=verify-full",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := DSN("db.internal", 5432, tc.database, tc.username, "abc123", tc.sslmode)
			if got != tc.want {
				t.Errorf("DSN() = %q, want %q", got, tc.want)
			}
		})
	}
}

// RDS picks the master password from a wider alphabet than keygen does, and an
// unescaped one moves where a URL parser thinks the host begins.
func TestAdminDSNEscapesThePassword(t *testing.T) {
	got := AdminDSN("db.internal", 5432, "postgres", "forge_admin", "a[b]c/d?e#f")
	want := "postgres://forge_admin:a%5Bb%5Dc%2Fd%3Fe%23f@db.internal:5432/postgres?sslmode=require"

	if got != want {
		t.Errorf("AdminDSN() = %q, want %q", got, want)
	}
}
