package main

import (
	"strings"
	"testing"
)

// setRequiredEnv sets every variable loadConfig requires, in us-east-2.
func setRequiredEnv(t *testing.T) {
	t.Helper()
	for name, value := range map[string]string{
		"AWS_REGION":                  "us-east-2",
		"FORGE_STAGE":                 "any-stage",
		"FORGE_DB_HOST":               "any-host",
		"FORGE_DB_MASTER_SECRET_ARN":  "any-arn",
		"FORGE_HOSTNAME_SUFFIX":       "any.example",
		"FORGE_INGOT_HOSTNAME_SUFFIX": "any.example",
	} {
		t.Setenv(name, value)
	}
}

func TestLoadConfigRefusesABackupReplicaInTheFunctionsOwnRegion(t *testing.T) {
	setRequiredEnv(t)
	t.Setenv("FORGE_BACKUP_REPLICA_REGION", "us-east-2") // the same as AWS_REGION

	_, err := loadConfig()
	if err == nil || !strings.Contains(err.Error(), "FORGE_BACKUP_REPLICA_REGION is us-east-2, the function's own region") {
		t.Errorf("loadConfig() error = %v, want one naming the shared region", err)
	}
}

func TestLoadConfigAcceptsABackupReplicaInAnotherRegion(t *testing.T) {
	setRequiredEnv(t)
	t.Setenv("FORGE_BACKUP_REPLICA_REGION", "eu-central-1")

	cfg, err := loadConfig()
	if err != nil {
		t.Fatalf("loadConfig() error = %v", err)
	}
	if cfg.BackupReplicaRegion != "eu-central-1" {
		t.Errorf("BackupReplicaRegion = %q, want eu-central-1", cfg.BackupReplicaRegion)
	}
}

func TestLoadConfigReadsTheDelegatorStore(t *testing.T) {
	cases := map[string]string{
		"unset":    "dynamodb",
		"dynamodb": "dynamodb",
		"postgres": "postgres",
	}
	for value, want := range cases {
		t.Run("FORGE_DELEGATOR_STORE "+value, func(t *testing.T) {
			setRequiredEnv(t)
			if value != "unset" {
				t.Setenv("FORGE_DELEGATOR_STORE", value)
			}

			cfg, err := loadConfig()
			if err != nil {
				t.Fatalf("loadConfig() error = %v", err)
			}
			if cfg.DelegatorStore != want {
				t.Errorf("DelegatorStore = %q, want %q", cfg.DelegatorStore, want)
			}
		})
	}
}

func TestLoadConfigRefusesAnUnknownDelegatorStore(t *testing.T) {
	setRequiredEnv(t)
	t.Setenv("FORGE_DELEGATOR_STORE", "Postgres")

	_, err := loadConfig()
	if err == nil || !strings.Contains(err.Error(), `FORGE_DELEGATOR_STORE is "Postgres"`) {
		t.Errorf("loadConfig() error = %v, want one naming the value", err)
	}
}
