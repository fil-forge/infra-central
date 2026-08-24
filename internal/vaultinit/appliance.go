package vaultinit

import (
	"context"
	"fmt"
	"sort"
	"strings"

	"github.com/openbao/openbao/api/v2"
)

// This file reconciles the transit keys regional appliances seal against, one
// key and one policy per region, per fil-one/RFC#21.
//
// Reconciliation rather than creation, because a key that exists in OpenBao and
// in no committed list is either a region somebody forgot to record or a rename
// that is about to strand a node. Neither should pass silently, so the caller
// compares both directions and refuses to proceed on anything it cannot account
// for. See PlanApplianceKeys.

// AppliancePlan is what one reconciliation pass will do.
type AppliancePlan struct {
	// Active regions get their key and policy ensured.
	Active []string
	// Remove regions have a key today and are recorded as retired.
	Remove []string
}

// PlanApplianceKeys compares the keys OpenBao holds against the two committed
// lists and reports what to reconcile.
//
// It fails on anything it cannot account for, and that is the point of the whole
// arrangement. Deleting a transit key permanently bricks the node behind it,
// dev applies on merge with no confirmation, and a mistyped region label in a
// single list would read as "delete this key and create that one". Requiring
// every existing key to appear in one list or the other turns that typo into a
// failed apply.
func PlanApplianceKeys(existing, active, retired []string) (AppliancePlan, error) {
	activeSet := setOf(active)
	retiredSet := setOf(retired)

	var both []string
	for _, region := range active {
		if retiredSet[region] {
			both = append(both, region)
		}
	}
	if len(both) > 0 {
		sort.Strings(both)
		return AppliancePlan{}, fmt.Errorf(
			"region %s appears in both appliance_regions and retired_appliance_regions; a region is either live or retired",
			strings.Join(both, ", "))
	}

	var remove, unaccounted []string
	for _, region := range existing {
		switch {
		case activeSet[region]:
		case retiredSet[region]:
			remove = append(remove, region)
		default:
			unaccounted = append(unaccounted, region)
		}
	}
	if len(unaccounted) > 0 {
		sort.Strings(unaccounted)
		return AppliancePlan{}, fmt.Errorf(
			"no list names the appliance region %s, which has a transit key: add it to appliance_regions to keep that key, or to retired_appliance_regions to destroy it and permanently end that node's ability to unseal",
			strings.Join(unaccounted, ", "))
	}

	return AppliancePlan{Active: active, Remove: remove}, nil
}

// EnsureApplianceTransitKeys creates the transit key and policy for each region,
// and returns the names it created. Existing keys are left exactly as they are:
// a key is the only thing standing between a node and an unreadable disk, so
// nothing here rewrites one.
func EnsureApplianceTransitKeys(ctx context.Context, client *api.Client, regions []string) ([]string, error) {
	var created []string
	for _, region := range regions {
		name := ApplianceKeyName(region)

		existing, err := client.Logical().ReadWithContext(ctx, transitKeyPath(name))
		if err != nil {
			return created, fmt.Errorf("read transit key %s: %w", name, err)
		}
		if existing == nil {
			// aes256-gcm96 is the transit default and what the seal expects.
			// exportable and allow_plaintext_backup stay at their false
			// defaults: the whole point of the key is that it cannot be copied
			// out of central, so a node's disk is unreadable once the key is
			// gone.
			_, err := client.Logical().WriteWithContext(ctx, transitKeyPath(name), map[string]any{
				"type": "aes256-gcm96",
			})
			if err != nil {
				return created, fmt.Errorf("create transit key %s: %w", name, err)
			}
			created = append(created, name)
		}

		// The policy is written on every pass. It is derived entirely from the
		// region label, so a rewrite cannot change what it grants, and writing
		// it unconditionally is what repairs one edited by hand.
		if err := client.Sys().PutPolicyWithContext(ctx, name, appliancePolicy(name)); err != nil {
			return created, fmt.Errorf("write policy %s: %w", name, err)
		}
	}
	return created, nil
}

// RemoveApplianceTransitKey deletes a retired region's policy and key.
//
// This is RFC 21's kill lever fired deliberately: the node behind this key can
// never unseal again, and everything on its disks stays encrypted forever. The
// caller reaches here only for a region a committed list says is retired.
func RemoveApplianceTransitKey(ctx context.Context, client *api.Client, region string) error {
	name := ApplianceKeyName(region)

	if err := client.Sys().DeletePolicyWithContext(ctx, name); err != nil {
		return fmt.Errorf("delete policy %s: %w", name, err)
	}

	// A transit key refuses deletion until its own config allows it, which is
	// OpenBao's guard against exactly the mistake this operation is. Setting the
	// flag and deleting are two calls by design.
	_, err := client.Logical().WriteWithContext(ctx, transitKeyPath(name)+"/config", map[string]any{
		"deletion_allowed": true,
	})
	if err != nil {
		return fmt.Errorf("allow deletion of transit key %s: %w", name, err)
	}

	if _, err := client.Logical().DeleteWithContext(ctx, transitKeyPath(name)); err != nil {
		return fmt.Errorf("delete transit key %s: %w", name, err)
	}
	return nil
}

// ApplianceRegions returns the region labels that have a transit key today,
// derived from the key names under the appliance prefix.
func ApplianceRegions(ctx context.Context, client *api.Client) ([]string, error) {
	resp, err := client.Logical().ListWithContext(ctx, "transit/keys")
	if err != nil {
		return nil, fmt.Errorf("list transit keys: %w", err)
	}
	// A transit mount holding no keys lists as an empty response rather than an
	// error, which is the normal state of a stage with no appliances.
	if resp == nil {
		return nil, nil
	}

	raw, ok := resp.Data["keys"].([]any)
	if !ok {
		return nil, nil
	}

	var regions []string
	for _, entry := range raw {
		name, ok := entry.(string)
		if !ok {
			continue
		}
		if region, found := strings.CutPrefix(name, AppliancePrefix); found {
			regions = append(regions, region)
		}
	}
	sort.Strings(regions)
	return regions, nil
}

// appliancePolicy grants a node update on exactly the two transit paths its
// seal calls, so a stolen node token unseals that node and does nothing else.
//
// The token needs its own renewal too. It is periodic, and a periodic token
// renews by calling auth/token/renew-self, which lives in the default policy;
// naming the path here keeps the grant explicit rather than resting on a token
// created with default policies attached.
func appliancePolicy(name string) string {
	return fmt.Sprintf(`
path "%[1]s/encrypt/%[2]s" {
  capabilities = ["update"]
}

path "%[1]s/decrypt/%[2]s" {
  capabilities = ["update"]
}

path "auth/token/renew-self" {
  capabilities = ["update"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}
`, TransitMount, name)
}

func transitKeyPath(name string) string {
	return TransitMount + "/keys/" + name
}

func setOf(values []string) map[string]bool {
	set := make(map[string]bool, len(values))
	for _, value := range values {
		set[value] = true
	}
	return set
}
