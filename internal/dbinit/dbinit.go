// Package dbinit creates one Postgres role and database per service on the
// shared RDS instance.
//
// This runs inside the provision Lambda rather than as managed resources because
// the deployment executes outside the VPC and cannot reach RDS. The Lambda is
// attached to the private subnets, so it can.
//
// The loop is smelt's, and its two properties are worth keeping: creation is
// conditional, so re-running is harmless, while the password is applied
// unconditionally, so a rotated secret takes effect without anyone dropping a
// role.
package dbinit

import (
	"context"
	"fmt"
	"net"
	"net/url"
	"regexp"
	"strconv"

	"github.com/jackc/pgx/v5"
)

// Database is one service's Postgres tenancy. Role name and database name are
// the same string, and the role owns the database.
type Database struct {
	Name     string
	Password string
}

// hexOnly guards the one place this package interpolates a value into SQL.
//
// ALTER ROLE ... PASSWORD takes a string literal, not a bind parameter, so the
// password is interpolated. Every password here comes from keygen.RandomHex and
// is therefore [0-9a-f], which cannot contain a quote or a backslash. This
// check makes that assumption fail loudly rather than silently becoming an
// injection the day some other caller supplies a different alphabet.
var hexOnly = regexp.MustCompile(`^[0-9a-f]+$`)

// Ensure creates each role and database if absent and sets each password.
func Ensure(ctx context.Context, conn *pgx.Conn, databases []Database) error {
	for _, db := range databases {
		if err := ensureOne(ctx, conn, db); err != nil {
			return fmt.Errorf("ensure database %s: %w", db.Name, err)
		}
	}
	return nil
}

func ensureOne(ctx context.Context, conn *pgx.Conn, db Database) error {
	if !hexOnly.MatchString(db.Password) {
		return fmt.Errorf("password for %s is not hex-only; refusing to interpolate it into SQL", db.Name)
	}
	quotedName := pgx.Identifier{db.Name}.Sanitize()

	var roleExists bool
	if err := conn.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = $1)`, db.Name,
	).Scan(&roleExists); err != nil {
		return fmt.Errorf("check role: %w", err)
	}
	if !roleExists {
		if _, err := conn.Exec(ctx, `CREATE ROLE `+quotedName+` WITH LOGIN`); err != nil {
			return fmt.Errorf("create role: %w", err)
		}
	}

	// Applied every run so that rotating the stored secret is enough to rotate
	// the credential.
	if _, err := conn.Exec(ctx,
		`ALTER ROLE `+quotedName+` WITH LOGIN PASSWORD '`+db.Password+`'`,
	); err != nil {
		return fmt.Errorf("set role password: %w", err)
	}

	var dbExists bool
	if err := conn.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = $1)`, db.Name,
	).Scan(&dbExists); err != nil {
		return fmt.Errorf("check database: %w", err)
	}
	if !dbExists {
		// CREATE DATABASE cannot run inside a transaction block, which is why
		// this package uses a plain connection rather than a pool with an
		// implicit transaction.
		if _, err := conn.Exec(ctx,
			`CREATE DATABASE `+quotedName+` OWNER `+quotedName,
		); err != nil {
			return fmt.Errorf("create database: %w", err)
		}
	}

	return nil
}

// DSN renders a service's connection string. TLS is required: RDS terminates
// it, and unlike smelt's single-VM deployment the traffic crosses a subnet
// boundary here.
func DSN(host string, port int, db Database) string {
	return connectionString(host, port, db.Name, db.Name, db.Password)
}

// AdminDSN renders the master connection string. RDS generates that password
// itself, so unlike the hex service passwords it can carry punctuation that
// changes where a URL parser finds the host.
func AdminDSN(host string, port int, database, username, password string) string {
	return connectionString(host, port, database, username, password)
}

func connectionString(host string, port int, database, username, password string) string {
	dsn := url.URL{
		Scheme:   "postgres",
		User:     url.UserPassword(username, password),
		Host:     net.JoinHostPort(host, strconv.Itoa(port)),
		Path:     "/" + database,
		RawQuery: "sslmode=require",
	}
	return dsn.String()
}
