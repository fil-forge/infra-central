package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"strings"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/secretsmanager"
	"github.com/jackc/pgx/v5"

	"github.com/fil-forge/infra-central/internal/dbinit"
	"github.com/fil-forge/infra-central/internal/keygen"
)

// List of services that need an Ed25519 service identity.
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

// multibaseServices read their identity as a multibase string in an environment
// variable rather than as a PEM.
//
// Only these two get the multibase copy. It is the same private key in a second
// encoding, so writing it for a service that reads the PEM would leave a
// duplicate of live signing material to guard and to rotate for no reader.
//
// See https://linear.app/filecoin-foundation/issue/FIL-1061
var multibaseServices = map[string]bool{
	"delegator":       true,
	"signing-service": true,
}

// databaseConsumers are the services that each get a Postgres role and
// database of the same name on the shared instance. openbao is here because it
// stores its data in Postgres rather than on a volume, which is what lets it
// survive task replacement.
var databaseConsumers = []string{
	"sprue",
	"hilt",
	"swarf",
	"plc",
	"openbao",
}

// pandoraDatabase is the compatibility server's database. The server's code
// hardcodes the name.
const pandoraDatabase = "pandora"

// pandoraOwner owns that database and every table in it. Only the estate
// loader connects as this role, so it gets no timeout: a restore runs long.
const pandoraOwner = "pandora_admin"

// pandoraTimeout matches the per-statement budget the compatibility server's
// daemons are written for.
var pandoraTimeout = []dbinit.Setting{{Name: "statement_timeout", Value: "15s"}}

// pandoraLoginRoles are the roles the compatibility server's clients connect
// as. pandora_storage_server keeps the name the server's code hardcodes. Table
// privileges come from the server's grants file, applied by the owner once the
// tables exist.
var pandoraLoginRoles = []struct {
	name     string
	settings []dbinit.Setting
}{
	{name: "pandora_storage_server", settings: pandoraTimeout},
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

	slog.Info("ensuring service identities", "services", len(identityServices))
	freshIdentities, err := d.seedIdentities(ctx, resp)
	if err != nil {
		return nil, err
	}

	slog.Info("issuing proofs", "minted_identities", len(freshIdentities))
	if err := d.seedProofs(ctx, resp, freshIdentities); err != nil {
		return nil, err
	}

	slog.Info("ensuring wallets", "wallets", len(wallets))
	if err := d.seedWallets(ctx, resp); err != nil {
		return nil, err
	}

	slog.Info("ensuring shared secrets", "secrets", len(randomSecrets))
	if err := d.seedRandomSecrets(ctx, resp); err != nil {
		return nil, err
	}

	slog.Info("ensuring database passwords", "databases", len(databaseConsumers))
	databases, err := d.seedDatabasePasswords(ctx, resp)
	if err != nil {
		return nil, err
	}

	slog.Info("creating databases", "databases", len(databases))
	if err := d.createDatabases(ctx, databases); err != nil {
		return nil, err
	}

	slog.Info("storing connection strings", "databases", len(databases))
	if err := d.storeConnectionStrings(ctx, databases); err != nil {
		return nil, err
	}
	for _, db := range databases {
		resp.Databases = append(resp.Databases, db.Name)
	}

	if d.cfg.Pandora != nil {
		slog.Info("ensuring the pandora database", "roles", 1+len(pandoraLoginRoles))
		if err := d.seedPandora(ctx, resp, *d.cfg.Pandora); err != nil {
			return nil, err
		}
		resp.Databases = append(resp.Databases, pandoraDatabase)
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

		// The multibase form is derived from the PEM, so rewriting it is
		// reproducible rather than destructive.
		if multibaseServices[service] {
			if err := d.store.PutSecret(ctx, service, "identity-multibase", id.Multibase); err != nil {
				return nil, err
			}
		}

		// The DID is stored as the durable public record of this identity,
		// readable without decrypting anything.
		//
		// It is written once rather than on every apply: an unchanged key
		// always derives the same DID, so the rewrite only spent a
		// PutParameter against a 3 TPS quota. A rotation is the exception. The
		// operator deletes the private parameter and re-applies, which mints a
		// key deriving a different DID, and leaving the old one in place would
		// publish a DID that no longer matches the identity behind it.
		if created {
			err = d.store.PutPublic(ctx, service, "identity.did", id.DID)
		} else {
			_, _, err = d.store.EnsurePublic(ctx, service, "identity.did", func() (string, error) {
				return id.DID, nil
			})
		}
		if err != nil {
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
		webDID[service] = "did:web:" + d.serviceHostname(service)
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

		// Like the identity DID, the address derives deterministically from
		// the stored key, so it only needs a write when the key is new. A
		// rotated key (deleted and re-minted) takes the overwrite branch,
		// which keeps the published address matching the wallet behind it.
		if created {
			err = d.store.PutPublic(ctx, spec.service, spec.name+".address", w.Address)
		} else {
			_, _, err = d.store.EnsurePublic(ctx, spec.service, spec.name+".address", func() (string, error) {
				return w.Address, nil
			})
		}
		if err != nil {
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
	databases := make([]dbinit.Database, 0, len(databaseConsumers))
	for _, service := range databaseConsumers {
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
	return d.ensureDatabases(ctx, d.cfg.centralDB(), databases)
}

func (d *deps) ensureDatabases(ctx context.Context, target dbTarget, databases []dbinit.Database) error {
	slog.Info("reading the RDS master secret", "secret", target.MasterSecret)
	master, err := d.masterCredentials(ctx, target.MasterSecret)
	if err != nil {
		return err
	}

	adminDSN := dbinit.AdminDSN(target.Host, target.Port, d.cfg.DBAdminDatabase,
		master.Username, master.Password)

	// A security group that drops the connection shows up as a long silence
	// rather than an error, so the host is worth having in the log before the
	// dial. The DSN itself is never logged, because it carries the master
	// password.
	slog.Info("connecting to postgres as master",
		"host", target.Host, "port", target.Port, "database", d.cfg.DBAdminDatabase)

	conn, err := pgx.Connect(ctx, adminDSN)
	if err != nil {
		return fmt.Errorf("connect to %s as master: %w", target.Host, err)
	}
	defer conn.Close(ctx)

	return dbinit.Ensure(ctx, conn, databases)
}

// seedPandora creates the compatibility server's database and its roles on
// that server's own cluster, and stores one DSN per role. Each role's
// parameters sit under a prefix of their own, so whoever installs a DSN on an
// appliance reads exactly the one it needs.
func (d *deps) seedPandora(ctx context.Context, resp *Response, target dbTarget) error {
	password := func(role string) (string, error) {
		service := ssmService(role)
		value, created, err := d.store.EnsureSecret(ctx, service, "postgres-password", keygen.RandomHex)
		if err != nil {
			return "", fmt.Errorf("ensure postgres password for %s: %w", role, err)
		}
		if created {
			resp.Created = append(resp.Created, d.store.Path(service, "postgres-password"))
		}
		return value, nil
	}

	ownerPassword, err := password(pandoraOwner)
	if err != nil {
		return err
	}
	db := dbinit.Database{Name: pandoraDatabase, Owner: pandoraOwner, Password: ownerPassword}
	for _, spec := range pandoraLoginRoles {
		rolePassword, err := password(spec.name)
		if err != nil {
			return err
		}
		db.LoginRoles = append(db.LoginRoles,
			dbinit.Role{Name: spec.name, Password: rolePassword, Settings: spec.settings})
	}

	if err := d.ensureDatabases(ctx, target, []dbinit.Database{db}); err != nil {
		return err
	}

	for service, dsn := range pandoraDSNs(target, db) {
		if err := d.store.PutSecret(ctx, service, "postgres-dsn", dsn); err != nil {
			return err
		}
	}
	return nil
}

// pandoraDSNs renders every role's connection string to the pandora database,
// keyed by the SSM service it is stored under. They ask for verify-full
// because the server's clients reach the cluster across the internet, inside
// the VPN; each client supplies the RDS root bundle itself.
func pandoraDSNs(target dbTarget, db dbinit.Database) map[string]string {
	dsns := map[string]string{
		ssmService(db.OwnerRole()): dbinit.DSN(target.Host, target.Port, db.Name, db.OwnerRole(), db.Password, dbinit.SSLVerifyFull),
	}
	for _, role := range db.LoginRoles {
		dsns[ssmService(role.Name)] = dbinit.DSN(target.Host, target.Port, db.Name, role.Name, role.Password, dbinit.SSLVerifyFull)
	}
	return dsns
}

// ssmService turns a Postgres role name into the parameter prefix it is stored
// under, matching the hyphenated service names every other prefix uses.
func ssmService(role string) string {
	return strings.ReplaceAll(role, "_", "-")
}

// storeConnectionStrings writes each service the exact string it consumes.
//
// Storing the assembled DSN rather than the bare password is what keeps
// Terraform out of the business of building connection strings, which would
// otherwise put every password into state.
func (d *deps) storeConnectionStrings(ctx context.Context, databases []dbinit.Database) error {
	for _, db := range databases {
		dsn := dbinit.DSN(d.cfg.DBHost, d.cfg.DBPort, db.Name, db.Name, db.Password, dbinit.SSLRequire)
		if err := d.store.PutSecret(ctx, db.Name, "postgres-dsn", dsn); err != nil {
			return err
		}

		// plc takes credentials as a JSON blob rather than a URL, and wants the
		// port as a string.
		//
		// sslmode is no-verify rather than require because plc reaches Postgres
		// through node-postgres, which verifies the server certificate against
		// Node's own trust store. That store carries no Amazon RDS root, and the
		// image has no bundle to point NODE_EXTRA_CA_CERTS at, so require fails
		// the handshake. The connection is still encrypted, which is what the
		// instance's rds.force_ssl demands; leaving sslmode out altogether makes
		// RDS reject the connection with a pg_hba error naming no other cause.
		if db.Name == "plc" {
			creds, err := json.Marshal(map[string]string{
				"username": db.Name,
				"password": db.Password,
				"host":     d.cfg.DBHost,
				"port":     fmt.Sprintf("%d", d.cfg.DBPort),
				"database": db.Name,
				"sslmode":  "no-verify",
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
func (d *deps) masterCredentials(ctx context.Context, secretARN string) (masterCredentials, error) {
	out, err := d.secrets.GetSecretValue(ctx, &secretsmanager.GetSecretValueInput{
		SecretId: aws.String(secretARN),
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
