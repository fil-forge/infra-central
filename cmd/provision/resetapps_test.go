package main

import (
	"slices"
	"strings"
	"testing"
)

// The reset drops databases. A stage outside this list must never reach the
// drop, whatever the script in front of it checks.
func TestCheckResettableStage(t *testing.T) {
	cases := []struct {
		stage   string
		allowed bool
	}{
		{stage: "dev", allowed: true},
		{stage: "staging", allowed: true},
		{stage: "production"},
		{stage: "prod"},
		{stage: ""},
		{stage: "Dev"},
	}

	for _, c := range cases {
		t.Run("stage "+c.stage, func(t *testing.T) {
			err := checkResettableStage(c.stage)
			switch {
			case c.allowed && err != nil:
				t.Errorf("checkResettableStage(%q) = %v, want nil", c.stage, err)
			case !c.allowed && (err == nil || !strings.Contains(err.Error(), "refusing")):
				t.Errorf("checkResettableStage(%q) = %v, want a refusal", c.stage, err)
			}
		})
	}
}

// openbao's database is the platform's own state: dropping it uninitialises
// OpenBao and kills every appliance's unseal key.
func TestAppDatabasesNeverIncludeOpenBao(t *testing.T) {
	if slices.Contains(appDatabases, "openbao") {
		t.Errorf("appDatabases = %v, must not include openbao", appDatabases)
	}
}

// A database the seed phase does not create has no stored password to recreate
// it with, so every one the reset drops must be one seed owns.
func TestAppDatabasesAreSeededDatabases(t *testing.T) {
	for _, name := range appDatabases {
		if !slices.Contains(databaseConsumers, name) {
			t.Errorf("appDatabases has %q, which databaseConsumers %v does not create", name, databaseConsumers)
		}
	}
}
