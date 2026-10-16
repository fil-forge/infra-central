package onboard

import (
	"context"
	"fmt"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb/types"
)

// DynamoProviderInfo is the delegator's provider-info table, one row per Piri
// that completed `piri init`, keyed by the Piri's DID. The delegator writes it
// and has no command to remove a row, so removal deletes it directly, for the
// same reason DynamoAllowList writes directly.
//
// A row left behind outlives the Piri's sprue registration and keeps the
// endpoint it registered with.
type DynamoProviderInfo struct {
	client dynamoAPI
	table  string
}

// NewDynamoProviderInfo returns the provider info for a stage's delegator table.
func NewDynamoProviderInfo(client *dynamodb.Client, table string) *DynamoProviderInfo {
	return &DynamoProviderInfo{client: client, table: table}
}

// Has reports whether the delegator holds a row for the DID.
func (p *DynamoProviderInfo) Has(ctx context.Context, did string) (bool, error) {
	out, err := p.client.GetItem(ctx, &dynamodb.GetItemInput{
		TableName:            aws.String(p.table),
		Key:                  map[string]types.AttributeValue{"provider": &types.AttributeValueMemberS{Value: did}},
		ProjectionExpression: aws.String("provider"),
	})
	if err != nil {
		return false, fmt.Errorf("get %s from %s: %w", did, p.table, err)
	}
	return len(out.Item) > 0, nil
}

// Remove deletes the DID's row. Deleting a row that is not there succeeds.
func (p *DynamoProviderInfo) Remove(ctx context.Context, did string) error {
	return deleteKey(ctx, p.client, p.table, "provider", did)
}

// deleteKey deletes the item a table holds under a single string hash key.
func deleteKey(ctx context.Context, client dynamoAPI, table, key, value string) error {
	_, err := client.DeleteItem(ctx, &dynamodb.DeleteItemInput{
		TableName: aws.String(table),
		Key:       map[string]types.AttributeValue{key: &types.AttributeValueMemberS{Value: value}},
	})
	if err != nil {
		return fmt.Errorf("delete %s from %s: %w", value, table, err)
	}
	return nil
}
