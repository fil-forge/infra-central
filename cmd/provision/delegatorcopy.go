package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"slices"
	"strconv"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb/types"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// copyDelegatorRecordsPhase copies the delegator's allow list and provider
// registrations from its DynamoDB tables into its Postgres database, so a stage
// switched to Postgres keeps every appliance it had admitted and registered.
// Without the copy, each region would have to be onboarded again and each Piri
// would stay unregistered until its next `piri init`.
//
// Run it after the stage's delegator has started on Postgres, which is what
// creates the tables. A row already in Postgres is left as it is: it was written
// after the switch, so it is the newer one. That also makes the phase safe to
// run again.
//
// Nothing is written without Confirm. The dry run reports which rows each table
// would gain and which are already there.
func (d *deps) copyDelegatorRecordsPhase(ctx context.Context, req Request) (*Response, error) {
	if d.cfg.AllowListTable == "" || d.cfg.ProviderInfoTable == "" {
		return nil, fmt.Errorf("FORGE_ALLOW_LIST_TABLE and FORGE_PROVIDER_INFO_TABLE are required for the copy-delegator-records phase")
	}

	awsCfg, err := awsconfig.LoadDefaultConfig(ctx)
	if err != nil {
		return nil, fmt.Errorf("load AWS config: %w", err)
	}
	dynamo := dynamodb.NewFromConfig(awsCfg)

	slog.Info("reading the delegator's DynamoDB tables",
		"allow_list", d.cfg.AllowListTable, "provider_info", d.cfg.ProviderInfoTable)
	allowItems, err := scanTable(ctx, dynamo, d.cfg.AllowListTable)
	if err != nil {
		return nil, err
	}
	allowRows, err := allowListRowsFrom(allowItems)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", d.cfg.AllowListTable, err)
	}
	providerItems, err := scanTable(ctx, dynamo, d.cfg.ProviderInfoTable)
	if err != nil {
		return nil, err
	}
	providerRows, err := providerRowsFrom(providerItems)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", d.cfg.ProviderInfoTable, err)
	}

	conn, err := d.connectToDelegatorDatabase(ctx)
	if err != nil {
		return nil, err
	}
	defer func() { _ = conn.Close(ctx) }()

	slog.Info("reading what the delegator's database already holds",
		"allow_list_rows", len(allowRows), "provider_info_rows", len(providerRows))
	plan, err := planDelegatorCopy(ctx, conn, d.cfg.Stage, allowRows, providerRows)
	if err != nil {
		return nil, err
	}

	if !req.Confirm {
		slog.Info("delegator copy plan prepared",
			"allow_list_to_copy", len(plan.AllowList.ToCopy),
			"provider_info_to_copy", len(plan.ProviderInfo.ToCopy))
		return &Response{Phase: "copy-delegator-records", DryRun: true, DelegatorCopyPlan: plan}, nil
	}

	slog.Info("copying the delegator's records",
		"allow_list", plan.AllowList.ToCopy, "provider_info", plan.ProviderInfo.ToCopy)
	result, err := applyDelegatorCopy(ctx, conn, d.cfg.Stage, allowRows, providerRows)
	if err != nil {
		return nil, err
	}
	slog.Info("delegator records copied",
		"allow_list", result.AllowListCopied, "provider_info", result.ProviderInfoCopied)
	return &Response{Phase: "copy-delegator-records", DelegatorCopyResult: result}, nil
}

// DelegatorCopyPlan is what a confirmed run would copy. Every value in it is a
// public DID.
type DelegatorCopyPlan struct {
	Stage        string             `json:"stage"`
	AllowList    DelegatorTableCopy `json:"allow_list"`
	ProviderInfo DelegatorTableCopy `json:"provider_info"`
}

// DelegatorTableCopy compares one DynamoDB table with its Postgres table, by
// key.
type DelegatorTableCopy struct {
	// Read counts the items in the DynamoDB table.
	Read int `json:"read"`
	// ToCopy are the keys Postgres lacks.
	ToCopy []string `json:"to_copy"`
	// AlreadyPresent are the keys Postgres holds, which the copy leaves alone.
	AlreadyPresent []string `json:"already_present"`
}

// DelegatorCopyResult names the rows a confirmed run inserted.
type DelegatorCopyResult struct {
	Stage              string   `json:"stage"`
	AllowListCopied    []string `json:"allow_list_copied"`
	ProviderInfoCopied []string `json:"provider_info_copied"`
}

// allowListRow is one row of the delegator's allow_list table.
type allowListRow struct {
	DID     string
	AddedBy string
	Notes   string
	AddedAt time.Time
}

// providerRow is one row of the delegator's provider_info table.
type providerRow struct {
	Provider      string
	Endpoint      string
	Address       string
	ProofSet      int64
	OperatorEmail string
	Proofs        string
	Weight        int64
	InsertedAt    time.Time
	UpdatedAt     time.Time
}

func planDelegatorCopy(ctx context.Context, conn *pgx.Conn, stage string, allowRows []allowListRow, providerRows []providerRow) (*DelegatorCopyPlan, error) {
	allowKeys := make([]string, len(allowRows))
	for i, row := range allowRows {
		allowKeys[i] = row.DID
	}
	providerKeys := make([]string, len(providerRows))
	for i, row := range providerRows {
		providerKeys[i] = row.Provider
	}

	presentAllowed, err := presentKeys(ctx, conn, `SELECT did FROM allow_list WHERE did = ANY($1)`, "allow_list", allowKeys)
	if err != nil {
		return nil, err
	}
	presentProviders, err := presentKeys(ctx, conn, `SELECT provider FROM provider_info WHERE provider = ANY($1)`, "provider_info", providerKeys)
	if err != nil {
		return nil, err
	}

	return &DelegatorCopyPlan{
		Stage:        stage,
		AllowList:    compareKeys(allowKeys, presentAllowed),
		ProviderInfo: compareKeys(providerKeys, presentProviders),
	}, nil
}

// applyDelegatorCopy inserts every row in one transaction, so a failure leaves
// Postgres as it was and the phase can simply run again.
func applyDelegatorCopy(ctx context.Context, conn *pgx.Conn, stage string, allowRows []allowListRow, providerRows []providerRow) (*DelegatorCopyResult, error) {
	result := &DelegatorCopyResult{Stage: stage, AllowListCopied: []string{}, ProviderInfoCopied: []string{}}

	err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
		for _, row := range allowRows {
			tag, err := tx.Exec(ctx,
				`INSERT INTO allow_list (did, added_by, notes, added_at) VALUES ($1, $2, $3, $4)
				 ON CONFLICT (did) DO NOTHING`,
				row.DID, row.AddedBy, row.Notes, row.AddedAt)
			if err != nil {
				return explainMissingTable(fmt.Sprintf("copy %s into allow_list", row.DID), err)
			}
			if tag.RowsAffected() == 1 {
				result.AllowListCopied = append(result.AllowListCopied, row.DID)
			}
		}
		for _, row := range providerRows {
			tag, err := tx.Exec(ctx,
				`INSERT INTO provider_info
				   (provider, endpoint, address, proof_set, operator_email, proofs, weight, inserted_at, updated_at)
				 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
				 ON CONFLICT (provider) DO NOTHING`,
				row.Provider, row.Endpoint, row.Address, row.ProofSet, row.OperatorEmail,
				row.Proofs, row.Weight, row.InsertedAt, row.UpdatedAt)
			if err != nil {
				return explainMissingTable(fmt.Sprintf("copy %s into provider_info", row.Provider), err)
			}
			if tag.RowsAffected() == 1 {
				result.ProviderInfoCopied = append(result.ProviderInfoCopied, row.Provider)
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return result, nil
}

// presentKeys returns which of keys the query finds.
func presentKeys(ctx context.Context, conn *pgx.Conn, query, table string, keys []string) (map[string]bool, error) {
	rows, err := conn.Query(ctx, query, keys)
	if err != nil {
		return nil, explainMissingTable("read "+table, err)
	}
	found, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return nil, explainMissingTable("read "+table, err)
	}
	present := make(map[string]bool, len(found))
	for _, key := range found {
		present[key] = true
	}
	return present, nil
}

// compareKeys sorts keys into those Postgres lacks and those it holds.
func compareKeys(keys []string, present map[string]bool) DelegatorTableCopy {
	table := DelegatorTableCopy{Read: len(keys), ToCopy: []string{}, AlreadyPresent: []string{}}
	for _, key := range keys {
		if present[key] {
			table.AlreadyPresent = append(table.AlreadyPresent, key)
		} else {
			table.ToCopy = append(table.ToCopy, key)
		}
	}
	slices.Sort(table.ToCopy)
	slices.Sort(table.AlreadyPresent)
	return table
}

// explainMissingTable names the usual cause of a missing table: the delegator
// creates both as it first starts on Postgres.
func explainMissingTable(action string, err error) error {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "42P01" {
		return fmt.Errorf("%s: the table does not exist, so the delegator has not migrated its database yet; "+
			"switch the stage's delegator_store to postgres and wait for its task to start: %w", action, err)
	}
	return fmt.Errorf("%s: %w", action, err)
}

// scanTable reads every item, with strongly consistent reads.
func scanTable(ctx context.Context, client *dynamodb.Client, table string) ([]map[string]types.AttributeValue, error) {
	var items []map[string]types.AttributeValue
	pages := dynamodb.NewScanPaginator(client, &dynamodb.ScanInput{
		TableName:      aws.String(table),
		ConsistentRead: aws.Bool(true),
	})
	for pages.HasMorePages() {
		page, err := pages.NextPage(ctx)
		if err != nil {
			return nil, fmt.Errorf("scan %s: %w", table, err)
		}
		items = append(items, page.Items...)
	}
	return items, nil
}

// allowListRowsFrom reads the items the delegator, and the onboard phase before
// the move, wrote to the allow-list table: did, added_by, notes, and added_at
// as RFC 3339.
func allowListRowsFrom(items []map[string]types.AttributeValue) ([]allowListRow, error) {
	rows := make([]allowListRow, 0, len(items))
	for _, item := range items {
		did, err := requiredString(item, "did")
		if err != nil {
			return nil, err
		}
		addedBy, err := optionalString(item, "added_by")
		if err != nil {
			return nil, fmt.Errorf("item %s: %w", did, err)
		}
		notes, err := optionalString(item, "notes")
		if err != nil {
			return nil, fmt.Errorf("item %s: %w", did, err)
		}
		addedAt, err := requiredTime(item, "added_at")
		if err != nil {
			return nil, fmt.Errorf("item %s: %w", did, err)
		}
		rows = append(rows, allowListRow{DID: did, AddedBy: addedBy, Notes: notes, AddedAt: addedAt})
	}
	return rows, nil
}

// providerRowsFrom reads the items the delegator's DynamoDB store wrote to the
// provider-info table. It always wrote provider, proofSet, weight, proofs,
// insertedAt and updatedAt, and left out an endpoint, address or operator email
// that was empty.
func providerRowsFrom(items []map[string]types.AttributeValue) ([]providerRow, error) {
	rows := make([]providerRow, 0, len(items))
	for _, item := range items {
		provider, err := requiredString(item, "provider")
		if err != nil {
			return nil, err
		}
		row, err := providerRowFrom(provider, item)
		if err != nil {
			return nil, fmt.Errorf("item %s: %w", provider, err)
		}
		rows = append(rows, row)
	}
	return rows, nil
}

func providerRowFrom(provider string, item map[string]types.AttributeValue) (providerRow, error) {
	row := providerRow{Provider: provider}
	var err error
	if row.Endpoint, err = optionalString(item, "endpoint"); err != nil {
		return providerRow{}, err
	}
	if row.Address, err = optionalString(item, "address"); err != nil {
		return providerRow{}, err
	}
	if row.OperatorEmail, err = optionalString(item, "operatorEmail"); err != nil {
		return providerRow{}, err
	}
	if row.Proofs, err = requiredString(item, "proofs"); err != nil {
		return providerRow{}, err
	}
	if row.ProofSet, err = requiredInt64(item, "proofSet"); err != nil {
		return providerRow{}, err
	}
	if row.Weight, err = requiredInt64(item, "weight"); err != nil {
		return providerRow{}, err
	}
	if row.InsertedAt, err = requiredTime(item, "insertedAt"); err != nil {
		return providerRow{}, err
	}
	if row.UpdatedAt, err = requiredTime(item, "updatedAt"); err != nil {
		return providerRow{}, err
	}
	return row, nil
}

func requiredString(item map[string]types.AttributeValue, name string) (string, error) {
	value, err := optionalString(item, name)
	if err != nil {
		return "", err
	}
	if value == "" {
		return "", fmt.Errorf("attribute %s is missing or empty", name)
	}
	return value, nil
}

// optionalString returns "" for an absent attribute, which the provider_info
// and allow_list columns accept.
func optionalString(item map[string]types.AttributeValue, name string) (string, error) {
	attr, ok := item[name]
	if !ok {
		return "", nil
	}
	value, ok := attr.(*types.AttributeValueMemberS)
	if !ok {
		return "", fmt.Errorf("attribute %s is a %T, want a string", name, attr)
	}
	return value.Value, nil
}

func requiredInt64(item map[string]types.AttributeValue, name string) (int64, error) {
	attr, ok := item[name]
	if !ok {
		return 0, fmt.Errorf("attribute %s is missing", name)
	}
	value, ok := attr.(*types.AttributeValueMemberN)
	if !ok {
		return 0, fmt.Errorf("attribute %s is a %T, want a number", name, attr)
	}
	n, err := strconv.ParseInt(value.Value, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("attribute %s: %w", name, err)
	}
	return n, nil
}

func requiredTime(item map[string]types.AttributeValue, name string) (time.Time, error) {
	value, err := requiredString(item, name)
	if err != nil {
		return time.Time{}, err
	}
	t, err := time.Parse(time.RFC3339, value)
	if err != nil {
		return time.Time{}, fmt.Errorf("attribute %s: %w", name, err)
	}
	return t, nil
}
