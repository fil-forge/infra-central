package main

import (
	"cmp"
	"context"
	"fmt"
	"slices"
	"time"
)

// replicator is the part of secretstore.Store that replicating the keys needs.
type replicator interface {
	Name(service, name string) string
	EnsureReplica(ctx context.Context, secretARN, replicaRegion string) (bool, error)
	WaitForReplica(ctx context.Context, secretARN, replicaRegion string) error
}

// replicaWait bounds how long one seed waits for all the replicas to sync.
// Secrets Manager usually syncs a small secret within seconds, and the Lambda
// runs for at most ten minutes.
const replicaWait = 2 * time.Minute

// replicateKeys gives every secret the seed phase ensured a replica in the DR
// region, so losing the stage's region loses no key. It runs on every seed, so
// a stage seeded before replication existed gets its replicas on the next run,
// and a key minted later gets one in the run that mints it.
//
// The wallets go first. They hold funds, and a failure part-way through
// should leave them covered rather than the identities.
//
// It then waits until every replica is in sync, so a seed that returns has
// every key in the DR region, not just requested there.
func replicateKeys(ctx context.Context, keys replicator, region string, resp *Response) error {
	if region == "" {
		return nil
	}
	resp.BackupReplicaRegion = region

	order := replicationOrder(resp.Secrets)
	for _, key := range order {
		added, err := keys.EnsureReplica(ctx, resp.Secrets[key.service][key.name], region)
		if err != nil {
			return fmt.Errorf("replicate %s/%s: %w", key.service, key.name, err)
		}
		if added {
			resp.Replicated = append(resp.Replicated, keys.Name(key.service, key.name))
		}
	}

	waitCtx, cancel := context.WithTimeout(ctx, replicaWait)
	defer cancel()
	for _, key := range order {
		if err := keys.WaitForReplica(waitCtx, resp.Secrets[key.service][key.name], region); err != nil {
			return fmt.Errorf("wait for the replica of %s/%s: %w", key.service, key.name, err)
		}
	}
	return nil
}

type secretKey struct{ service, name string }

// replicationOrder lists the secrets with the wallets first and the rest in
// name order, so every run walks them the same way.
func replicationOrder(secrets map[string]map[string]string) []secretKey {
	// rank sorts the wallets ahead of everything else.
	rank := func(k secretKey) int {
		if slices.ContainsFunc(wallets, func(w walletSpec) bool { return w.service == k.service && w.name == k.name }) {
			return 0
		}
		return 1
	}

	var keys []secretKey
	for service, names := range secrets {
		for name := range names {
			keys = append(keys, secretKey{service: service, name: name})
		}
	}
	slices.SortFunc(keys, func(a, b secretKey) int {
		return cmp.Or(
			cmp.Compare(rank(a), rank(b)),
			cmp.Compare(a.service, b.service),
			cmp.Compare(a.name, b.name),
		)
	})
	return keys
}
