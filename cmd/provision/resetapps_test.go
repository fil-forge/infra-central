package main

import (
	"slices"
	"strings"
	"testing"
)

// The reset drops databases. A stage outside this list must never reach the
// drop, whatever the script in front of it checks, and prod only when the
// request asks for it.
func TestCheckResettableStage(t *testing.T) {
	cases := []struct {
		stage           string
		allowProduction bool
		allowed         bool
	}{
		{stage: "dev", allowed: true},
		{stage: "staging", allowed: true},
		{stage: "dev", allowProduction: true, allowed: true},
		{stage: "prod"},
		{stage: "prod", allowProduction: true, allowed: true},
		{stage: "production"},
		{stage: "production", allowProduction: true},
		{stage: ""},
		{stage: "", allowProduction: true},
		{stage: "Dev"},
		{stage: "Prod", allowProduction: true},
	}

	for _, c := range cases {
		name := "stage " + c.stage
		if c.allowProduction {
			name += " with allow_production"
		}
		t.Run(name, func(t *testing.T) {
			err := checkResettableStage(c.stage, c.allowProduction)
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

// An app database the reset skips keeps its rows across a reset, so the stage
// comes back half-forgotten. Every seeded database but openbao's is an app's.
func TestAppDatabasesCoverEverySeededApp(t *testing.T) {
	for _, name := range databaseConsumers {
		if name != "openbao" && !slices.Contains(appDatabases, name) {
			t.Errorf("databaseConsumers has %q, which appDatabases %v does not reset", name, appDatabases)
		}
	}
}
