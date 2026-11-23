package onboard

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

func TestPostgresAllowListHas(t *testing.T) {
	for _, found := range []bool{true, false} {
		t.Run(map[bool]string{true: "listed", false: "not listed"}[found], func(t *testing.T) {
			conn := &fakePG{found: found}
			list := &PostgresAllowList{conn: conn, stamp: allowListStamp("dev")}

			got, err := list.Has(context.Background(), "did:key:z6Mkpiri")
			if err != nil {
				t.Fatalf("Has() error = %v", err)
			}
			if got != found {
				t.Errorf("Has() = %v, want %v", got, found)
			}
		})
	}
}

func TestPostgresAllowListAddWritesTheDelegatorsColumns(t *testing.T) {
	conn := &fakePG{}
	list := &PostgresAllowList{conn: conn, stamp: allowListStamp("dev")}

	if err := list.Add(context.Background(), "did:key:z6Mkpiri"); err != nil {
		t.Fatalf("Add() error = %v", err)
	}

	want := []any{"did:key:z6Mkpiri", "infra-central onboard phase, stage dev", "regional appliance onboarding"}
	if !reflect.DeepEqual(conn.execArgs, want) {
		t.Errorf("Add() args = %v, want %v", conn.execArgs, want)
	}
}

// A missing table means the delegator has not migrated, which an operator
// must not read as the DID being absent.
func TestPostgresAllowListExplainsAMissingTable(t *testing.T) {
	missing := &pgconn.PgError{Code: undefinedTable, Message: `relation "allow_list" does not exist`}
	calls := map[string]func(*PostgresAllowList) error{
		"Has": func(list *PostgresAllowList) error {
			_, err := list.Has(context.Background(), "did:key:z6Mkpiri")
			return err
		},
		"Add": func(list *PostgresAllowList) error {
			return list.Add(context.Background(), "did:key:z6Mkpiri")
		},
	}

	for name, call := range calls {
		t.Run(name, func(t *testing.T) {
			list := &PostgresAllowList{conn: &fakePG{err: missing}, stamp: allowListStamp("dev")}

			err := call(list)
			if err == nil || !strings.Contains(err.Error(), "the delegator has not migrated its database yet") {
				t.Errorf("%s() error = %v, want one saying the delegator has not migrated", name, err)
			}
		})
	}
}

func TestPostgresAllowListPassesOtherErrorsThrough(t *testing.T) {
	refused := errors.New("connection refused")
	list := &PostgresAllowList{conn: &fakePG{err: refused}, stamp: allowListStamp("dev")}

	_, err := list.Has(context.Background(), "did:key:z6Mkpiri")
	if !errors.Is(err, refused) || strings.Contains(err.Error(), "migrated") {
		t.Errorf("Has() error = %v, want the connection error without the migration hint", err)
	}
}

// fakePG answers every query with found, or fails every call with err.
type fakePG struct {
	found    bool
	err      error
	execArgs []any
}

func (f *fakePG) QueryRow(ctx context.Context, sql string, args ...any) pgx.Row {
	return fakeRow{found: f.found, err: f.err}
}

func (f *fakePG) Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error) {
	f.execArgs = args
	return pgconn.NewCommandTag("INSERT 0 1"), f.err
}

type fakeRow struct {
	found bool
	err   error
}

func (r fakeRow) Scan(dest ...any) error {
	if r.err != nil {
		return r.err
	}
	*dest[0].(*bool) = r.found
	return nil
}
