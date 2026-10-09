package main

import (
	"reflect"
	"strings"
	"testing"

	"github.com/fil-forge/infra-central/internal/dbinit"
)

func TestLoadPandoraTargetIsNilWhenNothingIsSet(t *testing.T) {
	got, err := loadPandoraTarget(func(string) string { return "" })
	if got != nil || err != nil {
		t.Errorf("loadPandoraTarget() = %v, %v; want nil, nil", got, err)
	}
}

func TestLoadPandoraTargetReadsAllThree(t *testing.T) {
	env := map[string]string{
		"FORGE_PANDORA_DB_HOST":              "fc-prod-pandora-db.cluster.example",
		"FORGE_PANDORA_DB_PORT":              "5432",
		"FORGE_PANDORA_DB_MASTER_SECRET_ARN": "arn:aws:secretsmanager:us-east-2:1:secret:rds!cluster",
	}

	got, err := loadPandoraTarget(func(name string) string { return env[name] })
	want := &dbTarget{
		Host:         "fc-prod-pandora-db.cluster.example",
		Port:         5432,
		MasterSecret: "arn:aws:secretsmanager:us-east-2:1:secret:rds!cluster",
	}
	if err != nil || !reflect.DeepEqual(got, want) {
		t.Errorf("loadPandoraTarget() = %+v, %v; want %+v, nil", got, err, want)
	}
}

// A partial set means Terraform wired the cluster wrong. Skipping it would
// leave the server without its roles and nothing in the log saying why.
func TestLoadPandoraTargetRejects(t *testing.T) {
	cases := []struct {
		name    string
		env     map[string]string
		wantErr string
	}{
		{
			name:    "a host without the rest",
			env:     map[string]string{"FORGE_PANDORA_DB_HOST": "db.example"},
			wantErr: "set without FORGE_PANDORA_DB_PORT, FORGE_PANDORA_DB_MASTER_SECRET_ARN",
		},
		{
			name: "a port that is not a number",
			env: map[string]string{
				"FORGE_PANDORA_DB_HOST":              "db.example",
				"FORGE_PANDORA_DB_PORT":              "postgres",
				"FORGE_PANDORA_DB_MASTER_SECRET_ARN": "arn:secret",
			},
			wantErr: "FORGE_PANDORA_DB_PORT is not a number",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := loadPandoraTarget(func(name string) string { return tc.env[name] })
			if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
				t.Errorf("loadPandoraTarget() error = %v, want it to contain %q", err, tc.wantErr)
			}
		})
	}
}

// Every role connects to the owner's database, verifies the server, and is
// stored under its own hyphenated prefix.
func TestPandoraDSNs(t *testing.T) {
	target := dbTarget{Host: "db.example", Port: 5432}
	db := dbinit.Database{
		Name:     "pandora",
		Owner:    "pandora_admin",
		Password: "aa",
		LoginRoles: []dbinit.Role{
			{Name: "pandora_storage_server", Password: "bb"},
			{Name: "ergo_proxy", Password: "cc"},
		},
	}

	got := pandoraDSNs(target, db)
	want := map[string]string{
		"pandora-admin":          "postgres://pandora_admin:aa@db.example:5432/pandora?sslmode=verify-full",
		"pandora-storage-server": "postgres://pandora_storage_server:bb@db.example:5432/pandora?sslmode=verify-full",
		"ergo-proxy":             "postgres://ergo_proxy:cc@db.example:5432/pandora?sslmode=verify-full",
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("pandoraDSNs() = %v, want %v", got, want)
	}
}
