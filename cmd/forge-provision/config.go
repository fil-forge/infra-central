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

	KMSKeyID string

	// HostnameSuffix builds the did:web identities the proofs are addressed
	// to, e.g. dev.fil.one.
	HostnameSuffix string

	DBHost          string
	DBPort          int
	DBAdminDatabase string
	DBMasterSecret  string // Secrets Manager ARN written by manage_master_user_password

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
}

func loadConfig() (config, error) {
	cfg := config{
		Stage:           os.Getenv("FORGE_STAGE"),
		Region:          os.Getenv("AWS_REGION"),
		KMSKeyID:        os.Getenv("FORGE_KMS_KEY_ID"),
		HostnameSuffix:  os.Getenv("FORGE_HOSTNAME_SUFFIX"),
		DBHost:          os.Getenv("FORGE_DB_HOST"),
		DBAdminDatabase: envOr("FORGE_DB_ADMIN_DATABASE", "postgres"),
		DBMasterSecret:  os.Getenv("FORGE_DB_MASTER_SECRET_ARN"),
		OpenBaoAddr:     os.Getenv("FORGE_OPENBAO_ADDR"),

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
		"FORGE_STAGE":                cfg.Stage,
		"FORGE_KMS_KEY_ID":           cfg.KMSKeyID,
		"FORGE_DB_HOST":              cfg.DBHost,
		"FORGE_DB_MASTER_SECRET_ARN": cfg.DBMasterSecret,
		"FORGE_HOSTNAME_SUFFIX":      cfg.HostnameSuffix,
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

func envOr(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}
