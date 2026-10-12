package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"
)

// config is the Lambda's environment, set by Terraform. Everything here is
// non-secret: endpoints, identifiers and names. The secrets this function
// touches are read from SSM and Secrets Manager at call time.
type config struct {
	Stage  string
	Region string

	// HostnameSuffix builds the did:web identities the proofs are addressed
	// to, e.g. dev.fil.one.
	HostnameSuffix string
	// IngotHostnameSuffix builds region-qualified Ingot identities, e.g.
	// latest.dev.filonecontent.com.
	IngotHostnameSuffix string

	DBHost          string
	DBPort          int
	DBAdminDatabase string
	DBMasterSecret  string // Secrets Manager ARN written by manage_master_user_password

	// Pandora is the compatibility server's cluster, separate from central's.
	// Nil in a stage without one, and the seed phase then skips it.
	Pandora *dbTarget

	OpenBaoAddr string

	// Chain configuration, used only by the fund phase. Not validated at
	// startup, because the seed and vault phases run without it; the fund phase
	// checks its own requirements.
	ChainRPCURL        string
	ChainID            int64
	USDFCAddress       string
	FilecoinPayAddress string
	FWSSAddress        string

	// PrivateCIDRs bounds hilt's AppRole to the VPC. See the note in
	// internal/vaultinit about what this does and does not buy.
	PrivateCIDRs []string

	// AllowListTable is the delegator's DynamoDB table, written by the onboard
	// phase. Not validated at startup, because every other phase runs without it.
	AllowListTable string
}

func loadConfig() (config, error) {
	cfg := config{
		Stage:               os.Getenv("FORGE_STAGE"),
		Region:              os.Getenv("AWS_REGION"),
		HostnameSuffix:      os.Getenv("FORGE_HOSTNAME_SUFFIX"),
		IngotHostnameSuffix: os.Getenv("FORGE_INGOT_HOSTNAME_SUFFIX"),
		DBHost:              os.Getenv("FORGE_DB_HOST"),
		DBAdminDatabase:     envOr("FORGE_DB_ADMIN_DATABASE", "postgres"),
		DBMasterSecret:      os.Getenv("FORGE_DB_MASTER_SECRET_ARN"),
		OpenBaoAddr:         os.Getenv("FORGE_OPENBAO_ADDR"),
		AllowListTable:      os.Getenv("FORGE_ALLOW_LIST_TABLE"),

		ChainRPCURL:        os.Getenv("FORGE_CHAIN_RPC_URL"),
		USDFCAddress:       os.Getenv("FORGE_USDFC_ADDRESS"),
		FilecoinPayAddress: os.Getenv("FORGE_FILECOIN_PAY_ADDRESS"),
		FWSSAddress:        os.Getenv("FORGE_FWSS_ADDRESS"),
	}

	port, err := strconv.Atoi(envOr("FORGE_DB_PORT", "5432"))
	if err != nil {
		return config{}, fmt.Errorf("FORGE_DB_PORT is not a number: %w", err)
	}
	cfg.DBPort = port

	cfg.Pandora, err = loadPandoraTarget(os.Getenv)
	if err != nil {
		return config{}, err
	}

	if raw := os.Getenv("FORGE_CHAIN_ID"); raw != "" {
		chainID, err := strconv.ParseInt(raw, 10, 64)
		if err != nil {
			return config{}, fmt.Errorf("FORGE_CHAIN_ID is not a number: %w", err)
		}
		cfg.ChainID = chainID
	}

	if cidrs := os.Getenv("FORGE_PRIVATE_CIDRS"); cidrs != "" {
		cfg.PrivateCIDRs = strings.Split(cidrs, ",")
	}

	// Fail on the whole set at once rather than one redeploy at a time.
	var missing []string
	for name, value := range map[string]string{
		"FORGE_STAGE":                 cfg.Stage,
		"FORGE_DB_HOST":               cfg.DBHost,
		"FORGE_DB_MASTER_SECRET_ARN":  cfg.DBMasterSecret,
		"FORGE_HOSTNAME_SUFFIX":       cfg.HostnameSuffix,
		"FORGE_INGOT_HOSTNAME_SUFFIX": cfg.IngotHostnameSuffix,
	} {
		if value == "" {
			missing = append(missing, name)
		}
	}
	if len(missing) > 0 {
		return config{}, fmt.Errorf("missing required environment: %s", strings.Join(missing, ", "))
	}

	return cfg, nil
}

// dbTarget is a cluster the seed phase connects to as its master user.
type dbTarget struct {
	Host         string
	Port         int
	MasterSecret string // Secrets Manager ARN written by manage_master_user_password
}

// centralDB is the cluster every central service's database lives on.
func (c config) centralDB() dbTarget {
	return dbTarget{Host: c.DBHost, Port: c.DBPort, MasterSecret: c.DBMasterSecret}
}

// loadPandoraTarget reads the compatibility server's cluster. Terraform sets
// all three variables or none, so a partial set is a wiring mistake and fails
// rather than being skipped.
func loadPandoraTarget(getenv func(string) string) (*dbTarget, error) {
	vars := []string{"FORGE_PANDORA_DB_HOST", "FORGE_PANDORA_DB_PORT", "FORGE_PANDORA_DB_MASTER_SECRET_ARN"}

	var set, missing []string
	for _, name := range vars {
		if getenv(name) == "" {
			missing = append(missing, name)
		} else {
			set = append(set, name)
		}
	}
	if len(set) == 0 {
		return nil, nil
	}
	if len(missing) > 0 {
		return nil, fmt.Errorf("%s set without %s; the pandora cluster needs all three",
			strings.Join(set, ", "), strings.Join(missing, ", "))
	}

	port, err := strconv.Atoi(getenv("FORGE_PANDORA_DB_PORT"))
	if err != nil {
		return nil, fmt.Errorf("FORGE_PANDORA_DB_PORT is not a number: %w", err)
	}
	return &dbTarget{
		Host:         getenv("FORGE_PANDORA_DB_HOST"),
		Port:         port,
		MasterSecret: getenv("FORGE_PANDORA_DB_MASTER_SECRET_ARN"),
	}, nil
}

func envOr(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}
