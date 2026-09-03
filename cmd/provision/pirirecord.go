package main

import (
	"context"
	"fmt"
	"sort"
	"strings"
)

// piriRecords is central's record of which Piri DIDs belong to which region,
// held in SSM under each appliance's own prefix.
//
// It exists because nothing else pairs the two. sprue's provider record carries
// no region and hilt's carries no Piri, so a region's set of Piri DIDs is
// knowable only at onboard time, when one request names both. A node whose Piri
// key is replaced would otherwise leave a provider row in sprue that no later run
// can attribute to a region.
//
// One parameter per DID rather than a list in one. The set has no fixed size, and
// a parameter written once obeys this package's never-overwrite rule; a list
// would have to be read, merged and rewritten on every onboard.
type piriRecords struct {
	store publicStore
}

// publicStore is the slice of ssmstore this record needs.
type publicStore interface {
	EnsurePublic(ctx context.Context, service, name string, generate func() (string, error)) (string, bool, error)
	ListPublic(ctx context.Context, service, subPrefix string) (map[string]string, error)
}

// piriSubPrefix is where a region's Piri DIDs sit, one parameter each, under the
// appliance's own prefix. A sub-prefix rather than the prefix itself: the
// appliance's prefix also holds its unseal credential's accessor and its stored
// delegation.
const piriSubPrefix = "piri"

// Recorded returns every Piri DID recorded for a region.
func (r *piriRecords) Recorded(ctx context.Context, region string) ([]string, error) {
	values, err := r.store.ListPublic(ctx, applianceService(region), piriSubPrefix)
	if err != nil {
		return nil, err
	}

	dids := make([]string, 0, len(values))
	for _, did := range values {
		dids = append(dids, did)
	}
	// Sorted so the plan an operator approves lists them in the same order twice.
	sort.Strings(dids)
	return dids, nil
}

// Record adds a Piri DID to a region's set.
func (r *piriRecords) Record(ctx context.Context, region, piriDID string) error {
	name, err := piriParameterName(piriDID)
	if err != nil {
		return err
	}
	_, _, err = r.store.EnsurePublic(ctx, applianceService(region), name,
		func() (string, error) { return piriDID, nil })
	return err
}

// piriParameterName renders the parameter a DID is recorded under.
//
// SSM parameter names allow letters, digits, dot, underscore, hyphen and slash,
// and a DID has colons, so the did:key's multibase tail is the name and the full
// DID is the value. Piri's identity is a did:key by design, on the operator's own
// domain rather than Forge's, so anything else is refused rather than mangled
// into a name. See docs/decisions/2026-08-region-onboarding.md.
func piriParameterName(piriDID string) (string, error) {
	tail, found := strings.CutPrefix(piriDID, "did:key:")
	if !found || tail == "" {
		return "", fmt.Errorf(
			"a Piri identity has to be a did:key, and %q is not; central records a region's Piri DIDs under names SSM accepts, which a colon is not",
			piriDID)
	}
	return piriSubPrefix + "/" + tail, nil
}
