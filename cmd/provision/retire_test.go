package main

import (
	"strings"
	"testing"
)

// A tenant is the console organisation and is not tied to a region: its buckets
// are served by whichever region created each one. Retiring a region must take
// that region's buckets and nothing above them, or an organisation loses the
// buckets it still holds elsewhere along with its members and keys.
func TestRegionDeletesLeaveTheOrganisation(t *testing.T) {
	stmts := regionDeletes(&regionDIDs{provider: "did:web:ingot", buckets: []string{"did:plc:b1"}})

	for _, s := range stmts {
		for _, table := range []string{"tenant", "access_key", "principal", "wrap_key"} {
			if strings.Contains(s.sql, " "+table+" ") {
				t.Errorf("the %s delete names %s: %q", s.table, table, s.sql)
			}
		}
	}
}

// The schema fixes the order. Buckets reference their provider ON DELETE
// RESTRICT, so the provider cannot go first, and delegations are keyed by
// nothing, so they would otherwise be left addressed to DIDs that have gone.
func TestRegionDeleteOrder(t *testing.T) {
	stmts := regionDeletes(&regionDIDs{provider: "did:web:ingot"})

	var tables []string
	for _, s := range stmts {
		tables = append(tables, s.table)
	}
	want := []string{"delegation", "bucket", "provider"}
	if len(tables) != len(want) {
		t.Fatalf("regionDeletes() touched %v, want %v", tables, want)
	}
	for i, table := range want {
		if tables[i] != table {
			t.Errorf("delete %d is %s, want %s", i, tables[i], table)
		}
	}
}

// Delegations are matched by DID because the table has no foreign key to
// anything. hilt's delegation to the Ingot names the provider, a bucket's names
// the bucket, so both have to be in the set or the rows outlive their subjects.
func TestRegionDIDsCoverProviderAndBuckets(t *testing.T) {
	dids := &regionDIDs{provider: "did:web:ingot", buckets: []string{"did:plc:b1", "did:plc:b2"}}

	got := dids.all()
	want := []string{"did:web:ingot", "did:plc:b1", "did:plc:b2"}
	if len(got) != len(want) {
		t.Fatalf("all() = %v, want %v", got, want)
	}
	for i, did := range want {
		if got[i] != did {
			t.Errorf("all()[%d] = %s, want %s", i, got[i], did)
		}
	}
}
