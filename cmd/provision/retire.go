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
// It runs in the Lambda because hilt's DSN is in SSM and the network path to RDS
// is here (the onboard phase runs here for the signing keys). The alternative,
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
		"provider": 1,
		"bucket":   len(dids.buckets),
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
//
// A tenant spans regions: it is the console organisation, and each of its
// buckets is served by whichever region created it. So a region owns its
// provider row and the buckets that name it, and nothing else. Tenants,
// principals, access keys and wrap keys belong to the organisation and outlive
// any one region.
type regionDIDs struct {
	provider string
	buckets  []string
}

// all returns every DID a delegation of this region's can name, in any of the
// three columns [delegationPredicate] matches.
func (r *regionDIDs) all() []string {
	return append([]string{r.provider}, r.buckets...)
}

// readRegionDIDs walks provider to bucket. It returns nil when hilt has no
// provider row for the region.
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

	rows, err := conn.Query(ctx, "SELECT id FROM bucket WHERE provider_id = $1", dids.provider)
	if err != nil {
		return nil, fmt.Errorf("read hilt's bucket rows under %s: %w", dids.provider, err)
	}
	defer rows.Close()
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		dids.buckets = append(dids.buckets, id)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("read hilt's bucket rows under %s: %w", dids.provider, err)
	}
	return dids, nil
}

// querier is the read half of pgx that both a connection and a transaction
// offer, so the plan can read outside a transaction and the delete inside one.
type querier interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
}

// delegationPredicate matches every delegation a region's DIDs appear in.
//
// All three columns are needed. hilt's delegation to the Ingot has the provider
// as its audience, while a key's grant over a bucket has the bucket as its
// subject and a tenant and an access key at its ends, both of which survive the
// retirement. A powerline grant carries no subject and so never matches, which
// is right: it is the organisation's and is not confined to a region.
const delegationPredicate = "issuer = ANY($1) OR audience = ANY($1) OR subject = ANY($1)"

// countDelegations reports how many delegation rows name any of these DIDs.
func countDelegations(ctx context.Context, conn querier, dids []string) (int, error) {
	var count int
	err := conn.QueryRow(ctx,
		"SELECT count(*) FROM delegation WHERE "+delegationPredicate,
		dids).Scan(&count)
	if err != nil {
		return 0, fmt.Errorf("count hilt's delegations for the region: %w", err)
	}
	return count, nil
}

// regionDelete is one statement of the retirement, named by the table it
// empties so a partial failure says how far it got.
type regionDelete struct {
	table string
	sql   string
	args  []any
}

// regionDeletes is every row a region retirement removes, in the order the
// schema demands. It is a function of the DIDs alone so the set a retirement
// touches can be read without a database in front of it.
func regionDeletes(dids *regionDIDs) []regionDelete {
	return []regionDelete{
		{"delegation", "DELETE FROM delegation WHERE " + delegationPredicate, []any{dids.all()}},
		{"bucket", "DELETE FROM bucket WHERE provider_id = $1", []any{dids.provider}},
		{"provider", "DELETE FROM provider WHERE id = $1", []any{dids.provider}},
	}
}

// deleteRegionRows removes one region's rows from hilt in a single transaction.
//
// The order is fixed by the schema: bucket references provider ON DELETE
// RESTRICT, so the provider cannot go first. Delegations go before both because
// they are keyed by nothing and would otherwise be left addressed to DIDs that
// no longer exist. A bucket's policy rows reference it ON DELETE CASCADE and go
// with it.
//
// Tenants stay. A tenant is the console organisation and may hold buckets in
// regions that are not being retired, so deleting it would take those with it.
// Its principals, access keys and wrap keys stay for the same reason. An access
// key scoped to a deleted bucket keeps that DID in its bucket list, which denies
// rather than grants: the array carries no foreign key, and a bucket DID is
// minted fresh and never reused.
//
// This takes none of the per-audience advisory locks hilt's delegation store
// writes under, so a grant written for a retired bucket while the retirement
// runs, or just after it commits, survives it. That is tolerated rather than
// solved. The lock is keyed by audience, and the audiences here are access keys
// belonging to organisations that span regions, so taking them would mean
// locking whole organisations that have nothing to do with the region. The row
// it leaves is inert: the bucket and the provider are both gone, so nothing
// authorizes against it. Retirement is also the last step, run once the region
// has been deregistered from sprue and the delegator by hand.
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

	deleted := map[string]int{}
	for _, s := range regionDeletes(dids) {
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
