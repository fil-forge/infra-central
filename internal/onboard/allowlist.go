package onboard

import (
	"context"
	"fmt"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb/types"
)

// dynamoAPI is the slice of the DynamoDB client this package uses.
type dynamoAPI interface {
	GetItem(ctx context.Context, in *dynamodb.GetItemInput, optFns ...func(*dynamodb.Options)) (*dynamodb.GetItemOutput, error)
	PutItem(ctx context.Context, in *dynamodb.PutItemInput, optFns ...func(*dynamodb.Options)) (*dynamodb.PutItemOutput, error)
}

// DynamoAllowList is the delegator's allow list, written directly.
//
// Directly, because the delegator's own `registrar store allow-did` command
// needs a shell in its task and there is none: it runs as a Fargate task in a
// private subnet with ECS Exec off. The table takes a single `did` hash key, so
// the item is unambiguous and there is nothing the command would do that this
// does not.
type DynamoAllowList struct {
	client dynamoAPI
	table  string
	// stamp names what wrote the item, in the delegator's own `added_by` field.
	stamp string
}

// NewDynamoAllowList returns the allow list for a stage's delegator table.
func NewDynamoAllowList(client *dynamodb.Client, table, stage string) *DynamoAllowList {
	return &DynamoAllowList{
		client: client,
		table:  table,
		stamp:  "infra-central onboard phase, stage " + stage,
	}
}

// Has reports whether a DID is on the list.
func (a *DynamoAllowList) Has(ctx context.Context, did string) (bool, error) {
	out, err := a.client.GetItem(ctx, &dynamodb.GetItemInput{
		TableName:            aws.String(a.table),
		Key:                  map[string]types.AttributeValue{"did": &types.AttributeValueMemberS{Value: did}},
		ProjectionExpression: aws.String("did"),
	})
	if err != nil {
		return false, fmt.Errorf("get %s from %s: %w", did, a.table, err)
	}
	return len(out.Item) > 0, nil
}

// Add puts a DID on the list.
//
// The item carries the three fields the delegator's own writer adds beside the
// key. They are not read by anything, and matching its shape means a row written
// here is indistinguishable from one written by its CLI.
func (a *DynamoAllowList) Add(ctx context.Context, did string) error {
	item := map[string]types.AttributeValue{
		"did":      &types.AttributeValueMemberS{Value: did},
		"added_by": &types.AttributeValueMemberS{Value: a.stamp},
		"added_at": &types.AttributeValueMemberS{Value: time.Now().UTC().Format(time.RFC3339)},
		"notes":    &types.AttributeValueMemberS{Value: "regional appliance onboarding"},
	}

	_, err := a.client.PutItem(ctx, &dynamodb.PutItemInput{
		TableName: aws.String(a.table),
		Item:      item,
	})
	if err != nil {
		return fmt.Errorf("put %s into %s: %w", did, a.table, err)
	}
	return nil
}
