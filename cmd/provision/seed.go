package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/secretsmanager"
	"github.com/jackc/pgx/v5"

	"github.com/fil-forge/infra-central/internal/dbinit"
	"github.com/fil-forge/infra-central/internal/keygen"
)

// identityServices each get an Ed25519 service identity.
//
// indexer and etracker are not deployed today. They exist because the delegator
// validates two UCAN proofs at startup that must be signed by them, exactly as
// in smelt. Both are expected to become real services, so they get ordinary
// per-service parameter directories rather than being filed as anonymous
// issuers, and their private keys are kept so the proofs can be re-signed after
// an identity rotation.
var identityServices = []string{
	"sprue",
	"hilt",
	"swarf",
	"delegator",
	"signing-service",
	"indexer",
	"etracker",
}

// databaseServices each get a Postgres role and database of the same name on
// the shared instance. openbao is here because it stores its data in Postgres
// rather than on a volume, which is what lets it survive task replacement.
var databaseServices = []string{
	"sprue",
	"hilt",
	"swarf",
	"plc",
	"openbao",
}

// walletSpec is a secp256k1 key and the serialization its consumer reads.
type walletSpec struct {
	service string
	name    string
	encode  func(*keygen.EVMWallet) string
}

// These two hold real funds on Filecoin. Their private keys are the most
// valuable material this function handles, and the reason every write goes
// through EnsureSecret rather than an overwrite.
var wallets = []walletSpec{
	{service: "signing-service", name: "payer-key", encode: (*keygen.EVMWallet).RawHex},
	{service: "delegator", name: "transactor-key", encode: (*keygen.EVMWallet).Hex0x},
}

// randomSecrets are shared bearer tokens with no structure beyond being secret.
var randomSecrets = []struct{ service, name string }{
	{service: "hilt", name: "partner-key"},
}

// seed mints identities, wallets and passwords, then creates the databases.
func (d *deps) seed(ctx context.Context) (*Response, error) {
	resp := &Response{
		Phase:     "seed",
		DIDs:      map[string]string{},
		Addresses: map[string]string{},
		Created:   []string{},
	}

	freshIdentities, err := d.seedIdentities(ctx, resp)
	if err != nil {
		return nil, err
	}
	if err := d.seedProofs(ctx, resp, freshIdentities); err != nil {
		return nil, err
	}
	if err := d.seedWallets(ctx, resp); err != nil {
		return nil, err
	}
	if err := d.seedRandomSecrets(ctx, resp); err != nil {
		return nil, err
	}

	databases, err := d.seedDatabasePasswords(ctx, resp)
	if err != nil {
		return nil, err
	}
	if err := d.createDatabases(ctx, databases); err != nil {
		return nil, err
	}
	if err := d.storeConnectionStrings(ctx, databases); err != nil {
		return nil, err
	}
	for _, db := range databases {
		resp.Databases = append(resp.Databases, db.Name)
	}

	slog.Info("seed complete",
		"created", len(resp.Created),
		"identities", len(resp.DIDs),
		"databases", len(resp.Databases))
	return resp, nil
}

// seedIdentities returns the set of services whose key was minted this run, so
// that the proofs those keys sign can be re-issued.
func (d *deps) seedIdentities(ctx context.Context, resp *Response) (map[string]bool, error) {
	fresh := map[string]bool{}

	for _, service := range identityServices {
		pemValue, created, err := d.store.EnsureSecret(ctx, service, "identity", func() (string, error) {
			id, err := keygen.GenerateIdentity()
			if err != nil {
				return "", err
			}
			return string(id.PrivatePEM), nil
		})
		if err != nil {
			return nil, fmt.Errorf("ensure identity for %s: %w", service, err)
		}

		// Re-derive from whatever is stored rather than from what was just
		// generated. On the idempotent path they are the same value; on a
		// concurrent-write path the stored one is authoritative.
		id, err := keygen.ParseIdentity([]byte(pemValue))
		if err != nil {
			return nil, fmt.Errorf("parse stored identity for %s: %w", service, err)
		}

		// The multibase form and the public material are both derived from the
		// PEM, so rewriting them is reproducible rather than destructive.
		if err := d.store.PutSecret(ctx, service, "identity-multibase", id.Multibase); err != nil {
			return nil, err
		}
		if err := d.store.PutPublic(ctx, service, "identity.pub", string(id.PublicPEM)); err != nil {
			return nil, err
		}
		if err := d.store.PutPublic(ctx, service, "identity.did", id.DID); err != nil {
			return nil, err
		}

		resp.DIDs[service] = id.DID
		if created {
			fresh[service] = true
			resp.Created = append(resp.Created, d.store.Path(service, "identity"))
		}
	}

	return fresh, nil
}

// seedProofs issues the UCAN delegations the delegator and hilt need at
// startup.
//
// A delegation looks derived but is not reproducible: ucantone mints a random
// 16-byte nonce per delegation, so re-issuing one produces entirely different
// bytes and a different CID. Rewriting on every apply would therefore churn the
// parameter and invalidate anything holding the previous delegation, so an
// existing proof is left alone.
//
// The exception is a freshly minted issuer key, which makes any proof it signed
// unverifiable. smelt tracks the same dependency, skipping a committed proof
// unless one of the keys behind it was regenerated that run.
func (d *deps) seedProofs(ctx context.Context, resp *Response, freshIdentities map[string]bool) error {
	if d.cfg.HostnameSuffix == "" {
		return fmt.Errorf("FORGE_HOSTNAME_SUFFIX is required: proofs are addressed to did:web identities")
	}

	// Services authenticate each other by did:web, derived from the hostname
	// the ALB serves, not by the did:key in the identity parameters.
	webDID := map[string]string{}
	for _, service := range identityServices {
		webDID[service] = fmt.Sprintf("did:web:%s.%s", service, d.cfg.HostnameSuffix)
	}

	for _, proof := range keygen.Proofs(webDID) {
		issue := func() (string, error) {
			issuerPEM, err := d.store.GetSecret(ctx, proof.Issuer, "identity")
			if err != nil {
				return "", fmt.Errorf("read %s identity to sign the %s proof: %w", proof.Issuer, proof.Name, err)
			}
			return keygen.IssueProof([]byte(issuerPEM), proof)
		}

		if freshIdentities[proof.Issuer] {
			// The old proof was signed by a key that no longer exists, so
			// keeping it would leave the consumer holding an unverifiable
			// delegation.
			delegation, err := issue()
			if err != nil {
				return err
			}
			if err := d.store.PutPublic(ctx, proof.Consumer, proof.Name, delegation); err != nil {
				return err
			}
			resp.Created = append(resp.Created, d.store.Path(proof.Consumer, proof.Name))
			continue
		}

		_, created, err := d.store.EnsurePublic(ctx, proof.Consumer, proof.Name, issue)
		if err != nil {
			return err
		}
		if created {
			resp.Created = append(resp.Created, d.store.Path(proof.Consumer, proof.Name))
		}
	}

	return nil
}

func (d *deps) seedWallets(ctx context.Context, resp *Response) error {
	for _, spec := range wallets {
		stored, created, err := d.store.EnsureSecret(ctx, spec.service, spec.name, func() (string, error) {
			w, err := keygen.GenerateEVMWallet()
			if err != nil {
				return "", err
			}
			return spec.encode(w), nil
		})
		if err != nil {
			return fmt.Errorf("ensure wallet %s/%s: %w", spec.service, spec.name, err)
		}

		w, err := parseWallet(spec, stored)
		if err != nil {
			return fmt.Errorf("parse stored wallet %s/%s: %w", spec.service, spec.name, err)
		}

		if err := d.store.PutPublic(ctx, spec.service, spec.name+".address", w.Address); err != nil {
			return err
		}

		resp.Addresses[spec.service+"/"+spec.name] = w.Address
		if created {
			resp.Created = append(resp.Created, d.store.Path(spec.service, spec.name))
		}
	}
	return nil
}

// parseWallet reads back whichever serialization this wallet is stored in.
func parseWallet(spec walletSpec, stored string) (*keygen.EVMWallet, error) {
	switch spec.name {
	case "transactor-key":
		return keygen.ParseEVMWalletHex0x(stored)
	default:
		return keygen.ParseEVMWalletRawHex(stored)
	}
}

func (d *deps) seedRandomSecrets(ctx context.Context, resp *Response) error {
	for _, secret := range randomSecrets {
		_, created, err := d.store.EnsureSecret(ctx, secret.service, secret.name, keygen.RandomHex)
		if err != nil {
			return fmt.Errorf("ensure secret %s/%s: %w", secret.service, secret.name, err)
		}
		if created {
			resp.Created = append(resp.Created, d.store.Path(secret.service, secret.name))
		}
	}
	return nil
}

func (d *deps) seedDatabasePasswords(ctx context.Context, resp *Response) ([]dbinit.Database, error) {
	databases := make([]dbinit.Database, 0, len(databaseServices))
	for _, service := range databaseServices {
		password, created, err := d.store.EnsureSecret(ctx, service, "postgres-password", keygen.RandomHex)
		if err != nil {
			return nil, fmt.Errorf("ensure postgres password for %s: %w", service, err)
		}
		if created {
			resp.Created = append(resp.Created, d.store.Path(service, "postgres-password"))
		}
		databases = append(databases, dbinit.Database{Name: service, Password: password})
	}
	return databases, nil
}

func (d *deps) createDatabases(ctx context.Context, databases []dbinit.Database) error {
	master, err := d.masterCredentials(ctx)
	if err != nil {
		return err
	}

	adminDSN := dbinit.AdminDSN(d.cfg.DBHost, d.cfg.DBPort, d.cfg.DBAdminDatabase,
		master.Username, master.Password)

	conn, err := pgx.Connect(ctx, adminDSN)
	if err != nil {
		return fmt.Errorf("connect to %s as master: %w", d.cfg.DBHost, err)
	}
	defer conn.Close(ctx)

	return dbinit.Ensure(ctx, conn, databases)
}

// storeConnectionStrings writes each service the exact string it consumes.
//
// Storing the assembled DSN rather than the bare password is what keeps
// Terraform out of the business of building connection strings, which would
// otherwise put every password into state.
func (d *deps) storeConnectionStrings(ctx context.Context, databases []dbinit.Database) error {
	for _, db := range databases {
		dsn := dbinit.DSN(d.cfg.DBHost, d.cfg.DBPort, db)
		if err := d.store.PutSecret(ctx, db.Name, "postgres-dsn", dsn); err != nil {
			return err
		}

		// plc takes credentials as a JSON blob rather than a URL, and wants the
		// port as a string.
		if db.Name == "plc" {
			creds, err := json.Marshal(map[string]string{
				"username": db.Name,
				"password": db.Password,
				"host":     d.cfg.DBHost,
				"port":     fmt.Sprintf("%d", d.cfg.DBPort),
				"database": db.Name,
			})
			if err != nil {
				return fmt.Errorf("encode plc credentials: %w", err)
			}
			if err := d.store.PutSecret(ctx, db.Name, "db-creds-json", string(creds)); err != nil {
				return err
			}
		}
	}
	return nil
}

type masterCredentials struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

// masterCredentials reads the secret RDS manages itself. Terraform never sees
// this value, because manage_master_user_password keeps it out of state.
func (d *deps) masterCredentials(ctx context.Context) (masterCredentials, error) {
	out, err := d.secrets.GetSecretValue(ctx, &secretsmanager.GetSecretValueInput{
		SecretId: aws.String(d.cfg.DBMasterSecret),
	})
	if err != nil {
		return masterCredentials{}, fmt.Errorf("read RDS master secret: %w", err)
	}

	var creds masterCredentials
	if err := json.Unmarshal([]byte(aws.ToString(out.SecretString)), &creds); err != nil {
		return masterCredentials{}, fmt.Errorf("decode RDS master secret: %w", err)
	}
	if creds.Username == "" || creds.Password == "" {
		return masterCredentials{}, fmt.Errorf("RDS master secret is missing username or password")
	}
	return creds, nil
}
