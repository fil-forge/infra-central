package main

import (
	"cmp"
	"context"
	"errors"
	"fmt"
	"log/slog"
	"slices"
	"time"

	"github.com/aws/smithy-go"
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
		added, err := ensureReplicaOnceGranted(ctx, keys, resp.Secrets[key.service][key.name], region, grantRetry{
			interval: grantRetryInterval,
			budget:   grantRetryBudget,
		})
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

// The apply that sets a replica region adds the ReplicateStageKeys grant and
// invokes the seed seconds later. IAM is eventually consistent, so the first
// calls can still be denied: staging's first such apply was denied 7.6 s after
// the grant was written, and a re-run passed. A denial is retried for up to
// grantRetryBudget per key. A grant that is really missing still fails the
// apply, about a minute later than it would without the retry.
const (
	grantRetryInterval = 5 * time.Second
	grantRetryBudget   = 60 * time.Second
)

type grantRetry struct {
	interval time.Duration
	budget   time.Duration
}

// ensureReplicaOnceGranted calls EnsureReplica and retries it while the call
// is denied, until retry.budget runs out. Any other error is returned at once.
// Every key is retried on its own: IAM propagates per host, so one call can
// pass and the next be denied.
func ensureReplicaOnceGranted(ctx context.Context, keys replicator, secretARN, region string, retry grantRetry) (bool, error) {
	deadline := time.Now().Add(retry.budget)
	for attempt := 1; ; attempt++ {
		added, err := keys.EnsureReplica(ctx, secretARN, region)
		if err == nil || !isAccessDenied(err) {
			return added, err
		}
		if time.Now().Add(retry.interval).After(deadline) {
			return false, fmt.Errorf("still denied after %d attempts over %s: %w", attempt, retry.budget, err)
		}

		slog.Warn("replication denied, retrying while the grant propagates",
			"secret", secretARN, "replica_region", region, "attempt", attempt, "retry_in", retry.interval, "error", err)
		select {
		case <-ctx.Done():
			return false, fmt.Errorf("%w (stopped retrying: %w)", err, ctx.Err())
		case <-time.After(retry.interval):
		}
	}
}

func isAccessDenied(err error) bool {
	var apiErr smithy.APIError
	return errors.As(err, &apiErr) && apiErr.ErrorCode() == "AccessDeniedException"
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
