package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"

	"github.com/jackc/pgx/v5"
)

// retirePhase removes a region's Ingot identity from everything central holds it
// in, so the region can be onboarded again under a different DID.
//
// It exists because the identity is recorded in three places that no re-run
// heals. hilt's provider row is keyed by DID and hilt ships no command to move
// one. The delegation hilt signed for that DID is stored in SSM under a name
// that does not mention the audience, so applianceProofIssuer finds it, logs
// "returning the delegation issued earlier" and hands back a proof addressed to
// the old DID: an onboard re-run after a DID change looks like a success and
// changes nothing. Deleting the stored proof is what re-arms that function to
// reissue, and it is the reason this phase exists rather than a note in a runbook.
//
// A `tofu destroy` of the stage does not do it either. SSM parameters outlive a
// stage by design, and this delegation is one of them. See README.md, "What
// survives a destroy".
//
// The node's own copy of the delegation is in its OpenBao and is replaced by the
// operator running store-hilt-proof.sh with the reissued proof.
//
// It runs in the Lambda for the same reason the onboard phase does: hilt's DSN is
// in SSM and the network path to RDS is here. The alternative,
// enable_execute_command on hilt's service, is a standing shell somebody has to
// remember to revert, and docs/decisions/2026-08-region-onboarding.md already
// turned that down.
func (d *deps) retirePhase(ctx context.Context, req Request) (*Response, error) {
	if req.Region == "" {
		return nil, fmt.Errorf("the retire phase needs a region")
	}

	dsn, err := d.store.GetSecret(ctx, "hilt", "postgres-dsn")
	if err != nil {
		return nil, fmt.Errorf("read hilt's database DSN: %w", err)
	}

	plan, err := d.planRetire(ctx, dsn, req.Region)
	if err != nil {
		return nil, err
	}

	if !req.Confirm {
		slog.Info("retire plan prepared",
			"region", req.Region, "provider", plan.ProviderDID, "empty", plan.Empty())
		return &Response{Phase: "retire", DryRun: true, RetirePlan: plan}, nil
	}

	if plan.Empty() {
		slog.Info("nothing to retire", "region", req.Region)
		return &Response{Phase: "retire", RetireResult: &RetireResult{Region: req.Region}}, nil
	}

	slog.Warn("retiring a region's Ingot identity from hilt and SSM",
		"region", req.Region, "provider", plan.ProviderDID)
	return d.applyRetire(ctx, dsn, plan)
}

// RetirePlan is what the phase found and what it would delete.
type RetirePlan struct {
	Region string `json:"region"`
	// ProviderDID is the Ingot DID hilt has registered for this region, read
	// rather than derived: the phase cannot know what the old scheme produced.
	// Empty means hilt has no row for the region.
	ProviderDID string `json:"provider_did,omitempty"`
	// Rows counts what the delete would remove from hilt, by table.
	Rows map[string]int `json:"rows,omitempty"`
	// Parameters are the fully qualified SSM names that exist and would go.
	Parameters []string `json:"parameters,omitempty"`
}

// Empty reports a region with nothing left to retire, which succeeds so the
// phase can be re-run after a failure partway through.
func (p *RetirePlan) Empty() bool {
	return p.ProviderDID == "" && len(p.Parameters) == 0
}

// RetireResult is what the phase actually deleted.
type RetireResult struct {
	Region      string         `json:"region"`
	ProviderDID string         `json:"provider_did,omitempty"`
	Rows        map[string]int `json:"rows,omitempty"`
	Parameters  []string       `json:"parameters,omitempty"`
}

// proofParameters are the two parameters holding the region's delegation: the
// proof and the sidecar recording which hilt key signed it.
//
// Named rather than deleted as a prefix. The appliance's prefix also holds
// unseal-token.accessor, which is the node's live unseal credential and what the
// vault phase's retirement reads to revoke it.
var proofParameters = []string{
	"hilt-ingot-s3-proof",
	"hilt-ingot-s3-proof" + proofIssuerKey,
}

// planRetire reads hilt and SSM and reports what a confirmed run would remove.
func (d *deps) planRetire(ctx context.Context, dsn, region string) (*RetirePlan, error) {
	plan := &RetirePlan{Region: region}

	service := applianceService(region)
	for _, name := range proofParameters {
		if _, found, err := d.store.LookupPublic(ctx, service, name); err != nil {
			return nil, err
		} else if found {
			plan.Parameters = append(plan.Parameters, d.store.Path(service, name))
		}
	}

	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		return nil, fmt.Errorf("connect to hilt's database: %w", err)
	}
	defer func() { _ = conn.Close(ctx) }()

	dids, err := readRegionDIDs(ctx, conn, region)
	if err != nil {
		return nil, err
	}
	if dids == nil {
		return plan, nil
	}

	plan.ProviderDID = dids.provider
	plan.Rows = map[string]int{
		"provider":   1,
		"tenant":     len(dids.tenants),
		"bucket":     len(dids.buckets),
		"access_key": len(dids.accessKeys),
	}

	delegations, err := countDelegations(ctx, conn, dids.all())
	if err != nil {
		return nil, err
	}
	plan.Rows["delegation"] = delegations

	return plan, nil
}

// applyRetire deletes hilt's rows in one transaction, then the stored proof.
//
// hilt first, because its rows are what a re-onboard collides with. The stored
// proof is deleted last for the same reason the vault phase destroys a transit
// key last: while it stands, the next run still sees a region to retire.
func (d *deps) applyRetire(ctx context.Context, dsn string, plan *RetirePlan) (*Response, error) {
	result := &RetireResult{Region: plan.Region, ProviderDID: plan.ProviderDID}

	if plan.ProviderDID != "" {
		rows, err := deleteRegionRows(ctx, dsn, plan.Region)
		if err != nil {
			return nil, err
		}
		result.Rows = rows
		slog.Info("deleted hilt's rows for the region", "region", plan.Region, "rows", rows)
	}

	deleted, err := d.store.Delete(ctx, applianceService(plan.Region), proofParameters...)
	if err != nil {
		return nil, err
	}
	result.Parameters = deleted

	slog.Info("retired the region's Ingot identity",
		"region", plan.Region, "parameters_deleted", len(deleted),
		"next", "re-run scripts/onboard-appliance.sh, which now reissues the delegation")
	return &Response{Phase: "retire", RetireResult: result}, nil
}

// regionDIDs are every DID hilt holds under one region's provider.
type regionDIDs struct {
	provider   string
	tenants    []string
	buckets    []string
	accessKeys []string
}

// all returns every DID, which is what a delegation's issuer or audience is
// matched against. hilt's delegation to the Ingot names the provider, while a
// tenant's names its own DID or an access key's.
func (r *regionDIDs) all() []string {
	dids := []string{r.provider}
	dids = append(dids, r.tenants...)
	dids = append(dids, r.buckets...)
	dids = append(dids, r.accessKeys...)
	return dids
}

// readRegionDIDs walks provider to tenant to bucket and access_key. It returns
// nil when hilt has no provider row for the region.
//
// The walk is by DID rather than by cascade because the delegation table has no
// foreign key to anything: its issuer and audience are plain text columns, so
// the rows for a region can only be found by knowing which DIDs belong to it.
func readRegionDIDs(ctx context.Context, conn querier, region string) (*regionDIDs, error) {
	dids := &regionDIDs{}

	err := conn.QueryRow(ctx, "SELECT id FROM provider WHERE region = $1", region).Scan(&dids.provider)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read hilt's provider row for region %s: %w", region, err)
	}

	queries := []struct {
		into  *[]string
		query string
	}{
		{&dids.tenants, "SELECT id FROM tenant WHERE provider_id = $1"},
		{&dids.buckets, "SELECT id FROM bucket WHERE tenant_id = ANY(SELECT id FROM tenant WHERE provider_id = $1)"},
		{&dids.accessKeys, "SELECT id FROM access_key WHERE tenant_id = ANY(SELECT id FROM tenant WHERE provider_id = $1)"},
	}
	for _, q := range queries {
		rows, err := conn.Query(ctx, q.query, dids.provider)
		if err != nil {
			return nil, fmt.Errorf("read hilt's rows under %s: %w", dids.provider, err)
		}
		for rows.Next() {
			var id string
			if err := rows.Scan(&id); err != nil {
				rows.Close()
				return nil, err
			}
			*q.into = append(*q.into, id)
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return nil, fmt.Errorf("read hilt's rows under %s: %w", dids.provider, err)
		}
	}
	return dids, nil
}

// querier is the read half of pgx that both a connection and a transaction
// offer, so the plan can read outside a transaction and the delete inside one.
type querier interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
}

// countDelegations reports how many delegation rows name any of these DIDs.
func countDelegations(ctx context.Context, conn querier, dids []string) (int, error) {
	var count int
	err := conn.QueryRow(ctx,
		"SELECT count(*) FROM delegation WHERE issuer = ANY($1) OR audience = ANY($1)",
		dids).Scan(&count)
	if err != nil {
		return 0, fmt.Errorf("count hilt's delegations for the region: %w", err)
	}
	return count, nil
}

// deleteRegionRows removes one region's rows from hilt in a single transaction.
//
// The order is fixed by the schema: tenant, bucket and access_key each reference
// their parent ON DELETE RESTRICT, so a parent cannot go first. Delegations go
// before all of them because they are keyed by nothing and would otherwise be
// left addressed to DIDs that no longer exist.
//
// wrap_key is left alone. It has no foreign key, so its rows do not block this,
// and it arrived in a hilt migration later than the deployed image: a DELETE
// against a table that is not there would abort the whole transaction. The rows
// it leaves are inert, because a tenant DID is minted fresh and never reused.
func deleteRegionRows(ctx context.Context, dsn, region string) (map[string]int, error) {
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		return nil, fmt.Errorf("connect to hilt's database: %w", err)
	}
	defer func() { _ = conn.Close(ctx) }()

	tx, err := conn.Begin(ctx)
	if err != nil {
		return nil, fmt.Errorf("begin the retirement transaction: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	dids, err := readRegionDIDs(ctx, tx, region)
	if err != nil {
		return nil, err
	}
	if dids == nil {
		return nil, fmt.Errorf("hilt's provider row for region %s went away mid-retirement", region)
	}

	statements := []struct {
		table string
		sql   string
		args  []any
	}{
		{"delegation", "DELETE FROM delegation WHERE issuer = ANY($1) OR audience = ANY($1)", []any{dids.all()}},
		{"access_key", "DELETE FROM access_key WHERE tenant_id = ANY($1)", []any{dids.tenants}},
		{"bucket", "DELETE FROM bucket WHERE tenant_id = ANY($1)", []any{dids.tenants}},
		{"tenant", "DELETE FROM tenant WHERE provider_id = $1", []any{dids.provider}},
		{"provider", "DELETE FROM provider WHERE id = $1", []any{dids.provider}},
	}

	deleted := map[string]int{}
	for _, s := range statements {
		tag, err := tx.Exec(ctx, s.sql, s.args...)
		if err != nil {
			return nil, fmt.Errorf("delete hilt's %s rows for region %s: %w", s.table, region, err)
		}
		deleted[s.table] = int(tag.RowsAffected())
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, fmt.Errorf("commit the retirement: %w", err)
	}
	return deleted, nil
}
