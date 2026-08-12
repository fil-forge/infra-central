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

func TestDSNRendersARequireTLSConnectionString(t *testing.T) {
	got := DSN("db.internal", 5432, Database{Name: "sprue", Password: "abc123"})
	want := "postgres://sprue:abc123@db.internal:5432/sprue?sslmode=require"

	if got != want {
		t.Errorf("DSN() = %q, want %q", got, want)
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
