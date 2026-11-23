package main

import (
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/service/dynamodb/types"
)

func s(value string) types.AttributeValue { return &types.AttributeValueMemberS{Value: value} }
func n(value string) types.AttributeValue { return &types.AttributeValueMemberN{Value: value} }

// An item as infra-central's onboard phase wrote it before the move.
func allowListItem() map[string]types.AttributeValue {
	return map[string]types.AttributeValue{
		"did":      s("did:key:z6Mkpiri"),
		"added_by": s("infra-central onboard phase, stage dev"),
		"added_at": s("2026-10-01T12:00:00Z"),
		"notes":    s("regional appliance onboarding"),
	}
}

// An item as the delegator's DynamoDB store wrote it on registration.
func providerItem() map[string]types.AttributeValue {
	return map[string]types.AttributeValue{
		"provider":      s("did:key:z6Mkpiri"),
		"endpoint":      s("https://piri-0.latest.dev.fil-forge.com"),
		"address":       s("0x1234567890abcdef1234567890abcdef12345678"),
		"proofSet":      n("42"),
		"weight":        n("0"),
		"operatorEmail": s("ops@example.com"),
		"proofs":        s("mAYIEAJ0"),
		"insertedAt":    s("2026-10-01T12:05:00Z"),
		"updatedAt":     s("2026-10-02T08:00:00Z"),
	}
}

func TestAllowListRowsFromReadsEveryAttribute(t *testing.T) {
	rows, err := allowListRowsFrom([]map[string]types.AttributeValue{allowListItem()})
	if err != nil {
		t.Fatalf("allowListRowsFrom() error = %v", err)
	}

	want := []allowListRow{{
		DID:     "did:key:z6Mkpiri",
		AddedBy: "infra-central onboard phase, stage dev",
		Notes:   "regional appliance onboarding",
		AddedAt: time.Date(2026, 10, 1, 12, 0, 0, 0, time.UTC),
	}}
	if !reflect.DeepEqual(rows, want) {
		t.Errorf("allowListRowsFrom() = %+v, want %+v", rows, want)
	}
}

func TestProviderRowsFromReadsEveryAttribute(t *testing.T) {
	rows, err := providerRowsFrom([]map[string]types.AttributeValue{providerItem()})
	if err != nil {
		t.Fatalf("providerRowsFrom() error = %v", err)
	}

	want := []providerRow{{
		Provider:      "did:key:z6Mkpiri",
		Endpoint:      "https://piri-0.latest.dev.fil-forge.com",
		Address:       "0x1234567890abcdef1234567890abcdef12345678",
		ProofSet:      42,
		OperatorEmail: "ops@example.com",
		Proofs:        "mAYIEAJ0",
		Weight:        0,
		InsertedAt:    time.Date(2026, 10, 1, 12, 5, 0, 0, time.UTC),
		UpdatedAt:     time.Date(2026, 10, 2, 8, 0, 0, 0, time.UTC),
	}}
	if !reflect.DeepEqual(rows, want) {
		t.Errorf("providerRowsFrom() = %+v, want %+v", rows, want)
	}
}

// The delegator's writer left out an empty endpoint, address or email, so
// their absence is an empty column rather than a refusal.
func TestProviderRowsFromAcceptsAbsentOptionalStrings(t *testing.T) {
	item := providerItem()
	delete(item, "endpoint")
	delete(item, "address")
	delete(item, "operatorEmail")

	rows, err := providerRowsFrom([]map[string]types.AttributeValue{item})
	if err != nil {
		t.Fatalf("providerRowsFrom() error = %v", err)
	}
	got := []string{rows[0].Endpoint, rows[0].Address, rows[0].OperatorEmail}
	if !reflect.DeepEqual(got, []string{"", "", ""}) {
		t.Errorf("endpoint, address, email = %q, want all empty", got)
	}
}

func TestAllowListRowsFromRefusesAnItem(t *testing.T) {
	cases := []struct {
		name    string
		change  func(map[string]types.AttributeValue)
		wantErr string
	}{
		{"without a did", func(i map[string]types.AttributeValue) { delete(i, "did") }, "attribute did is missing or empty"},
		{"without added_at", func(i map[string]types.AttributeValue) { delete(i, "added_at") }, "item did:key:z6Mkpiri: attribute added_at is missing"},
		{"with added_at not RFC 3339", func(i map[string]types.AttributeValue) { i["added_at"] = s("yesterday") }, "attribute added_at: parsing time"},
		{"with notes as a number", func(i map[string]types.AttributeValue) { i["notes"] = n("1") }, "attribute notes is a *types.AttributeValueMemberN, want a string"},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			item := allowListItem()
			c.change(item)

			_, err := allowListRowsFrom([]map[string]types.AttributeValue{item})
			if err == nil || !strings.Contains(err.Error(), c.wantErr) {
				t.Errorf("allowListRowsFrom() error = %v, want one containing %q", err, c.wantErr)
			}
		})
	}
}

func TestProviderRowsFromRefusesAnItem(t *testing.T) {
	cases := []struct {
		name    string
		change  func(map[string]types.AttributeValue)
		wantErr string
	}{
		{"without a provider", func(i map[string]types.AttributeValue) { delete(i, "provider") }, "attribute provider is missing or empty"},
		{"without proofs", func(i map[string]types.AttributeValue) { delete(i, "proofs") }, "item did:key:z6Mkpiri: attribute proofs is missing or empty"},
		{"without a weight", func(i map[string]types.AttributeValue) { delete(i, "weight") }, "attribute weight is missing"},
		{"with proofSet as a string", func(i map[string]types.AttributeValue) { i["proofSet"] = s("42") }, "attribute proofSet is a *types.AttributeValueMemberS, want a number"},
		{"with a proofSet beyond int64", func(i map[string]types.AttributeValue) { i["proofSet"] = n("18446744073709551615") }, "attribute proofSet: strconv.ParseInt"},
		{"with updatedAt not RFC 3339", func(i map[string]types.AttributeValue) { i["updatedAt"] = s("2026-10-02") }, "attribute updatedAt: parsing time"},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			item := providerItem()
			c.change(item)

			_, err := providerRowsFrom([]map[string]types.AttributeValue{item})
			if err == nil || !strings.Contains(err.Error(), c.wantErr) {
				t.Errorf("providerRowsFrom() error = %v, want one containing %q", err, c.wantErr)
			}
		})
	}
}

func TestCompareKeysSplitsMissingFromPresent(t *testing.T) {
	got := compareKeys(
		[]string{"did:key:c", "did:key:a", "did:key:b"},
		map[string]bool{"did:key:b": true},
	)

	want := DelegatorTableCopy{
		Read:           3,
		ToCopy:         []string{"did:key:a", "did:key:c"},
		AlreadyPresent: []string{"did:key:b"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("compareKeys() = %+v, want %+v", got, want)
	}
}
