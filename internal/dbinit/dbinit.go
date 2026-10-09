// Package dbinit creates one Postgres role and database per service on the
// shared RDS instance, plus any further login roles a database's clients use.
//
// This runs inside the provision Lambda rather than as Terraform resources
// because HCP Terraform executes outside the VPC and cannot reach RDS. The
// Lambda is attached to the private subnets, so it can.
//
// Creation is conditional, so re-running is harmless, while the password is
// applied unconditionally, so a rotated secret takes effect without anyone
// dropping a role.
package dbinit

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/url"
	"regexp"
	"strconv"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// Database is one service's Postgres tenancy. Role name and database name are
// the same string, and the role owns the database.
//
// LoginRoles are for a database whose clients connect as roles other than its
// owner. They get LOGIN, a password and their settings, and nothing else: no
// membership, no grants. Table privileges belong to whoever owns the tables.
type Database struct {
	Name       string
	Password   string
	LoginRoles []Role
}

// Role is a login role that does not own a database.
type Role struct {
	Name     string
	Password string
	Settings []Setting
}

// Setting is a per-role default, applied as ALTER ROLE ... SET.
type Setting struct {
	Name  string
	Value string
}

// SSLMode is the libpq sslmode a connection string asks for.
type SSLMode string

const (
	// SSLRequire encrypts without checking the server's certificate. Central's
	// services use it, inside the VPC.
	SSLRequire SSLMode = "require"
	// SSLVerifyFull also checks the certificate chain and the host name. The
	// client supplies the RDS root bundle, e.g. through PGSSLROOTCERT.
	SSLVerifyFull SSLMode = "verify-full"
)

// hexOnly guards the one place this package interpolates a value into SQL.
//
// ALTER ROLE ... PASSWORD takes a string literal, not a bind parameter, so the
// password is interpolated. Every password here comes from keygen.RandomHex and
// is therefore [0-9a-f], which cannot contain a quote or a backslash. This
// check makes that assumption fail loudly rather than silently becoming an
// injection the day some other caller supplies a different alphabet.
var hexOnly = regexp.MustCompile(`^[0-9a-f]+$`)

// allowedSettings are the role settings a caller may ask for. ALTER ROLE ...
// SET takes neither its name nor its value as a bind parameter, so both are
// interpolated; the name comes from this list and the value must match
// durationValue, for the same reason as hexOnly.
var allowedSettings = map[string]bool{
	"statement_timeout":                   true,
	"idle_in_transaction_session_timeout": true,
}

var durationValue = regexp.MustCompile(`^[0-9]+(ms|s|min)?$`)

// Ensure creates each role and database if absent and sets each password and
// role setting. Every input is checked before the first statement runs, so a
// bad one fails the call without leaving some databases done.
func Ensure(ctx context.Context, conn *pgx.Conn, databases []Database) error {
	for _, db := range databases {
		if err := validate(db); err != nil {
			return fmt.Errorf("ensure database %s: %w", db.Name, err)
		}
	}
	for _, db := range databases {
		if err := ensureOne(ctx, conn, db); err != nil {
			return fmt.Errorf("ensure database %s: %w", db.Name, err)
		}
	}
	return nil
}

func validate(db Database) error {
	if !hexOnly.MatchString(db.Password) {
		return fmt.Errorf("password for %s is not hex-only; refusing to interpolate it into SQL", db.Name)
	}
	for _, role := range db.LoginRoles {
		if !hexOnly.MatchString(role.Password) {
			return fmt.Errorf("password for %s is not hex-only; refusing to interpolate it into SQL", role.Name)
		}
		for _, setting := range role.Settings {
			if !allowedSettings[setting.Name] {
				return fmt.Errorf("role %s: setting %q is not one dbinit applies", role.Name, setting.Name)
			}
			if !durationValue.MatchString(setting.Value) {
				return fmt.Errorf("role %s: %s = %q is not a duration like 15s; refusing to interpolate it into SQL",
					role.Name, setting.Name, setting.Value)
			}
		}
	}
	return nil
}

func ensureOne(ctx context.Context, conn *pgx.Conn, db Database) error {
	quotedName := pgx.Identifier{db.Name}.Sanitize()

	if err := ensureLoginRole(ctx, conn, db.Name, db.Password); err != nil {
		return err
	}

	var dbExists bool
	if err := conn.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = $1)`, db.Name,
	).Scan(&dbExists); err != nil {
		return fmt.Errorf("check database: %w", err)
	}
	if !dbExists {
		// PostgreSQL 16 lets only a member that can SET ROLE to the owner
		// create a database for it. The RDS master user is not a superuser,
		// and creating the role gave it ADMIN OPTION but no membership.
		// Re-granting an existing membership is a notice, not an error.
		if _, err := conn.Exec(ctx, `GRANT `+quotedName+` TO CURRENT_USER`); err != nil {
			return fmt.Errorf("grant role to admin: %w", err)
		}

		// CREATE DATABASE cannot run inside a transaction block, which is why
		// this package uses a plain connection rather than a pool with an
		// implicit transaction.
		if _, err := conn.Exec(ctx,
			`CREATE DATABASE `+quotedName+` OWNER `+quotedName,
		); err != nil && !isDuplicate(err) {
			return fmt.Errorf("create database: %w", err)
		}
	}

	for _, role := range db.LoginRoles {
		if err := ensureLoginRole(ctx, conn, role.Name, role.Password); err != nil {
			return err
		}
		quotedRole := pgx.Identifier{role.Name}.Sanitize()
		for _, setting := range role.Settings {
			if _, err := conn.Exec(ctx,
				`ALTER ROLE `+quotedRole+` SET `+setting.Name+` = '`+setting.Value+`'`,
			); err != nil {
				return fmt.Errorf("set %s for role %s: %w", setting.Name, role.Name, err)
			}
		}
	}

	return nil
}

func ensureLoginRole(ctx context.Context, conn *pgx.Conn, name, password string) error {
	quotedName := pgx.Identifier{name}.Sanitize()

	var roleExists bool
	if err := conn.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = $1)`, name,
	).Scan(&roleExists); err != nil {
		return fmt.Errorf("check role %s: %w", name, err)
	}
	if !roleExists {
		// A concurrent run can create the role between the check and here;
		// duplicate_object means the desired state is reached, not a failure.
		if _, err := conn.Exec(ctx, `CREATE ROLE `+quotedName+` WITH LOGIN`); err != nil && !isDuplicate(err) {
			return fmt.Errorf("create role %s: %w", name, err)
		}
	}

	// Applied every run so that rotating the stored secret is enough to rotate
	// the credential.
	if _, err := conn.Exec(ctx,
		`ALTER ROLE `+quotedName+` WITH LOGIN PASSWORD '`+password+`'`,
	); err != nil {
		return fmt.Errorf("set password for role %s: %w", name, err)
	}
	return nil
}

// isDuplicate reports whether err is Postgres saying the role or database
// already exists: duplicate_object (42710) or duplicate_database (42P04).
func isDuplicate(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && (pgErr.Code == "42710" || pgErr.Code == "42P04")
}

// DSN renders a client's connection string to database as username. TLS is
// always on: the cluster enforces it with rds.force_ssl.
func DSN(host string, port int, database, username, password string, sslmode SSLMode) string {
	return connectionString(host, port, database, username, password, sslmode)
}

// AdminDSN renders the master connection string. RDS generates that password
// itself, so unlike the hex service passwords it can carry punctuation that
// changes where a URL parser finds the host.
func AdminDSN(host string, port int, database, username, password string) string {
	return connectionString(host, port, database, username, password, SSLRequire)
}

func connectionString(host string, port int, database, username, password string, sslmode SSLMode) string {
	dsn := url.URL{
		Scheme:   "postgres",
		User:     url.UserPassword(username, password),
		Host:     net.JoinHostPort(host, strconv.Itoa(port)),
		Path:     "/" + database,
		RawQuery: "sslmode=" + string(sslmode),
	}
	return dsn.String()
}
