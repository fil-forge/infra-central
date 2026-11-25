package main

import (
	"reflect"
	"strings"
	"testing"
)

var analyzeTestConfig = config{
	Stage:          "prod",
	DBHost:         "fc-prod.cluster.example",
	DBPort:         5432,
	DBMasterSecret: "arn:central",
	Pandora: &dbTarget{
		Host:         "fc-prod-pandora-db.cluster.example",
		Port:         5432,
		MasterSecret: "arn:pandora",
	},
}

type analyzeTargetResult struct {
	Target    dbTarget
	Databases []string
}

func TestAnalyzeTargetResolves(t *testing.T) {
	central := analyzeTargetResult{Target: analyzeTestConfig.centralDB(), Databases: databaseConsumers}
	cases := map[string]analyzeTargetResult{
		"":        central,
		"central": central,
		"pandora": {Target: *analyzeTestConfig.Pandora, Databases: []string{"pandora"}},
	}

	for name, want := range cases {
		t.Run("target "+name, func(t *testing.T) {
			target, databases, err := analyzeTarget(analyzeTestConfig, name)
			got := analyzeTargetResult{Target: target, Databases: databases}
			if err != nil || !reflect.DeepEqual(got, want) {
				t.Errorf("analyzeTarget(%q) = %+v, %v; want %+v, nil", name, got, err, want)
			}
		})
	}
}

func TestAnalyzeTargetRejects(t *testing.T) {
	withoutPandora := analyzeTestConfig
	withoutPandora.Pandora = nil

	cases := []struct {
		name    string
		cfg     config
		target  string
		wantErr string
	}{
		{"pandora on a stage without the cluster", withoutPandora, "pandora", "stage prod has no pandora cluster"},
		{"an unknown target", analyzeTestConfig, "openbao", `unknown target "openbao"`},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, _, err := analyzeTarget(tc.cfg, tc.target)
			if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
				t.Errorf("analyzeTarget(%q) error = %v, want one containing %q", tc.target, err, tc.wantErr)
			}
		})
	}
}

func TestAnalyzeStatementListsEveryTable(t *testing.T) {
	got := analyzeStatement([]string{`public.blobs`, `public."Uploads"`})
	want := `ANALYZE public.blobs, public."Uploads"`
	if got != want {
		t.Errorf("analyzeStatement() = %q, want %q", got, want)
	}
}

func TestSkippedTablesErrorIsNilWithoutWarnings(t *testing.T) {
	if err := skippedTablesError(nil); err != nil {
		t.Errorf("skippedTablesError(nil) = %v, want nil", err)
	}
}

func TestSkippedTablesErrorNamesEveryWarning(t *testing.T) {
	err := skippedTablesError([]string{
		`permission denied to analyze "blobs", skipping it`,
		`permission denied to analyze "uploads", skipping it`,
	})
	want := `ANALYZE raised 2 warning(s): permission denied to analyze "blobs", skipping it; permission denied to analyze "uploads", skipping it`
	if err == nil || err.Error() != want {
		t.Errorf("skippedTablesError() = %v, want %q", err, want)
	}
}
