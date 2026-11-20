package main

import (
	"context"
	"fmt"
	"log/slog"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// analyze runs ANALYZE on every table in every database of one cluster: the
// stage's own cluster by default, or the pandora cluster when the request's
// target is "pandora".
//
// A major version upgrade does not carry the planner's statistics across, so
// until a table is analyzed again the planner guesses its size and row
// distribution. Autovacuum analyzes a table only once enough of its rows have
// changed, which a table read often and written rarely may never reach.
// Terraform invokes this phase after a cluster changes version, because HCP
// Terraform runs outside the VPC and cannot reach the database. An upgrade left
// to the maintenance window gets no invocation, and an operator runs the phase
// by hand once the window has passed.
//
// The phase only reads data, so running it again is safe.
func (d *deps) analyze(ctx context.Context, req Request) (*Response, error) {
	target, databases, err := analyzeTarget(d.cfg, req.Target)
	if err != nil {
		return nil, err
	}

	resp := &Response{Phase: "analyze", Analyzed: []string{}}
	for _, database := range databases {
		if err := d.analyzeDatabase(ctx, target, database); err != nil {
			return nil, fmt.Errorf("analyze database %s: %w", database, err)
		}
		resp.Analyzed = append(resp.Analyzed, database)
	}

	slog.Info("analyze complete", "host", target.Host, "databases", len(resp.Analyzed))
	return resp, nil
}

// analyzeTarget resolves the request's target to a cluster and the databases
// on it. A pandora target on a stage without the pandora cluster is an error
// rather than a no-op, so a wiring mistake cannot pass as a finished ANALYZE.
func analyzeTarget(cfg config, name string) (dbTarget, []string, error) {
	switch name {
	case "", "central":
		return cfg.centralDB(), databaseConsumers, nil
	case "pandora":
		if cfg.Pandora == nil {
			return dbTarget{}, nil, fmt.Errorf("target %q: stage %s has no pandora cluster configured", name, cfg.Stage)
		}
		return *cfg.Pandora, []string{pandoraDatabase}, nil
	default:
		return dbTarget{}, nil, fmt.Errorf("unknown target %q; want \"central\" or \"pandora\"", name)
	}
}

// analyzeDatabase analyzes the database's tables as the database's owner,
// which may analyze every table in it. The RDS master user is not a superuser,
// and ANALYZE skips a table its user may not analyze with a warning rather
// than an error, so warnings are collected and fail the phase.
func (d *deps) analyzeDatabase(ctx context.Context, target dbTarget, database string) error {
	var warnings []string
	collectWarnings := func(_ *pgconn.PgConn, notice *pgconn.Notice) {
		if notice.Severity == "WARNING" {
			warnings = append(warnings, notice.Message)
		}
	}

	conn, err := d.connectAsMasterTo(ctx, target, database, collectWarnings)
	if err != nil {
		return err
	}
	defer conn.Close(ctx)

	var owner string
	if err := conn.QueryRow(ctx,
		`SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = current_database()`,
	).Scan(&owner); err != nil {
		return fmt.Errorf("read the database's owner: %w", err)
	}
	quotedOwner := pgx.Identifier{owner}.Sanitize()

	// The seed phase granted this membership when it created the database.
	// Granting it again is a notice, and covers a database created before then.
	if _, err := conn.Exec(ctx, `GRANT `+quotedOwner+` TO CURRENT_USER`); err != nil {
		return fmt.Errorf("grant %s to the master user: %w", owner, err)
	}
	if _, err := conn.Exec(ctx, `SET ROLE `+quotedOwner); err != nil {
		return fmt.Errorf("set role %s: %w", owner, err)
	}

	tables, err := userTables(ctx, conn)
	if err != nil {
		return err
	}
	if len(tables) == 0 {
		slog.Info("no tables to analyze", "database", database)
		return nil
	}

	slog.Info("analyzing", "database", database, "owner", owner, "tables", len(tables))
	if _, err := conn.Exec(ctx, analyzeStatement(tables)); err != nil {
		return fmt.Errorf("analyze: %w", err)
	}
	return skippedTablesError(warnings)
}

// userTables lists the database's tables, partitioned tables and materialized
// views outside the system schemas, each already quoted by the server. The
// catalogs are left out: the shared ones belong to no database owner, so
// ANALYZE would skip them with a warning.
func userTables(ctx context.Context, conn *pgx.Conn) ([]string, error) {
	rows, err := conn.Query(ctx, `
		SELECT format('%I.%I', n.nspname, c.relname)
		FROM pg_class c
		JOIN pg_namespace n ON n.oid = c.relnamespace
		WHERE c.relkind IN ('r', 'p', 'm')
		  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
		  AND n.nspname NOT LIKE 'pg\_toast%'
		  AND n.nspname NOT LIKE 'pg\_temp\_%'
		ORDER BY 1`)
	if err != nil {
		return nil, fmt.Errorf("list tables: %w", err)
	}
	tables, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return nil, fmt.Errorf("list tables: %w", err)
	}
	return tables, nil
}

// analyzeStatement analyzes the given tables, which must already be quoted
// identifiers, in one statement.
func analyzeStatement(tables []string) string {
	return "ANALYZE " + strings.Join(tables, ", ")
}

// skippedTablesError turns the warnings ANALYZE raised into an error, so a
// table left without statistics fails the phase instead of passing quietly.
func skippedTablesError(warnings []string) error {
	if len(warnings) == 0 {
		return nil
	}
	return fmt.Errorf("ANALYZE raised %d warning(s): %s", len(warnings), strings.Join(warnings, "; "))
}
