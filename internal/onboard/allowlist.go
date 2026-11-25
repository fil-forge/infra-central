package onboard

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// allowListNotes is the note on every row the onboard phase adds.
const allowListNotes = "regional appliance onboarding"

// allowListStamp names what wrote a row, in the delegator's own added_by
// field.
func allowListStamp(stage string) string {
	return "infra-central onboard phase, stage " + stage
}

// pgAPI is the slice of a pgx connection this package uses.
type pgAPI interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
}

// undefinedTable is the Postgres error code for a table that does not exist.
const undefinedTable = "42P01"

// PostgresAllowList is the delegator's allow list in its own database, written
// directly.
//
// Directly, because the delegator's own `registrar store allow-did` command
// needs a shell in its task and there is none: it runs as a Fargate task in a
// private subnet with ECS Exec off.
//
// The table belongs to the delegator, whose migrations create it when it first
// starts on Postgres. The columns written here are a contract with those
// migrations; added_at is left to the column's default. See
// docs/decisions/2026-11-delegator-postgres.md.
type PostgresAllowList struct {
	conn  pgAPI
	stamp string
}

// NewPostgresAllowList returns the allow list behind a connection to the
// delegator's database.
func NewPostgresAllowList(conn *pgx.Conn, stage string) *PostgresAllowList {
	return &PostgresAllowList{conn: conn, stamp: allowListStamp(stage)}
}

// Has reports whether a DID is on the list.
func (a *PostgresAllowList) Has(ctx context.Context, did string) (bool, error) {
	var found bool
	err := a.conn.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM allow_list WHERE did = $1)`, did,
	).Scan(&found)
	if err != nil {
		return false, explainAllowListError(fmt.Sprintf("look up %s in the delegator's allow_list", did), err)
	}
	return found, nil
}

// Add puts a DID on the list. A DID already there is left as it is, the way
// the delegator's own writer treats it.
func (a *PostgresAllowList) Add(ctx context.Context, did string) error {
	_, err := a.conn.Exec(ctx,
		`INSERT INTO allow_list (did, added_by, notes) VALUES ($1, $2, $3) ON CONFLICT (did) DO NOTHING`,
		did, a.stamp, allowListNotes)
	if err != nil {
		return explainAllowListError(fmt.Sprintf("insert %s into the delegator's allow_list", did), err)
	}
	return nil
}

// explainAllowListError names the usual cause of a missing table. The
// delegator creates allow_list as it starts on Postgres, so its absence means
// the delegator has not run against this database yet, not that the DID is
// missing.
func explainAllowListError(action string, err error) error {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == undefinedTable {
		return fmt.Errorf("%s: the table does not exist, so the delegator has not migrated its database yet; "+
			"check that the stage's delegator image supports Postgres and that its task has started: %w", action, err)
	}
	return fmt.Errorf("%s: %w", action, err)
}
