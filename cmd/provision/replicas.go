package main

import (
	"cmp"
	"context"
	"fmt"
	"log/slog"
	"slices"

	"github.com/fil-forge/infra-central/internal/keygen"
	"github.com/fil-forge/infra-central/internal/secretstore"
)

// replicator is the part of secretstore.Store that replicating the keys needs.
type replicator interface {
	Name(service, name string) string
	EnsureReplica(ctx context.Context, secretARN, replicaRegion string) (bool, error)
}

// replicateKeys gives every secret the seed phase ensured a replica in the DR
// region, so losing the stage's region loses no key. It runs on every seed, so
// a stage seeded before replication existed gets its replicas on the next run,
// and a key minted later gets one in the run that mints it.
//
// The wallets go first. They hold funds, and a failure part-way through
// should leave them covered rather than the identities.
func replicateKeys(ctx context.Context, keys replicator, region string, resp *Response) error {
	if region == "" {
		return nil
	}
	resp.ReplicaRegion = region

	for _, key := range replicationOrder(resp.Secrets) {
		added, err := keys.EnsureReplica(ctx, resp.Secrets[key.service][key.name], region)
		if err != nil {
			return fmt.Errorf("replicate %s/%s: %w", key.service, key.name, err)
		}
		if added {
			resp.Replicated = append(resp.Replicated, keys.Name(key.service, key.name))
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

// ReplicaCheck compares one key's replica with its primary by the public half
// each derives. Neither private value leaves the function.
type ReplicaCheck struct {
	Key string `json:"key"`
	// Primary is the DID or address the primary derives.
	Primary string `json:"primary"`
	// Replica is the same for the replica, empty when it has none.
	Replica string `json:"replica,omitempty"`
	Match   bool   `json:"match"`
}

// replicatedKey is a key the seed phase replicates and how to derive its
// public half.
type replicatedKey struct {
	service string
	name    string
	derive  func(value string) (string, error)
}

// replicatedKeys lists every key the seed phase stores in Secrets Manager.
func replicatedKeys() []replicatedKey {
	var keys []replicatedKey
	for _, spec := range wallets {
		keys = append(keys, replicatedKey{service: spec.service, name: spec.name, derive: spec.keySpec().derive})
	}
	for _, service := range identityServices {
		keys = append(keys, replicatedKey{service: service, name: "identity", derive: identitySpec(service).derive})
		if multibaseServices[service] {
			keys = append(keys, replicatedKey{service: service, name: "identity-multibase", derive: deriveMultibaseDID})
		}
	}
	return keys
}

func deriveMultibaseDID(value string) (string, error) {
	id, err := keygen.ParseIdentityMultibase(value)
	if err != nil {
		return "", err
	}
	return id.DID, nil
}

// keyReader is the part of secretstore.Store that reading a key needs.
type keyReader interface {
	Lookup(ctx context.Context, service, name string) (secretstore.Secret, bool, error)
}

// compareReplicas reads each key from both regions and compares the public
// halves they derive. A key missing from the primary region is an error; one
// missing from the replica region is a failed check.
func compareReplicas(ctx context.Context, primary, replica keyReader, keys []replicatedKey) ([]ReplicaCheck, error) {
	checks := make([]ReplicaCheck, 0, len(keys))
	for _, key := range keys {
		keyName := key.service + "/" + key.name

		stored, found, err := primary.Lookup(ctx, key.service, key.name)
		if err != nil {
			return nil, err
		}
		if !found {
			return nil, fmt.Errorf("%s is missing from the primary region; run the seed phase first", keyName)
		}
		primaryPublic, err := key.derive(stored.Value)
		if err != nil {
			return nil, fmt.Errorf("derive the public half of %s: %w", keyName, err)
		}

		check := ReplicaCheck{Key: keyName, Primary: primaryPublic}
		copied, found, err := replica.Lookup(ctx, key.service, key.name)
		if err != nil {
			return nil, err
		}
		if found {
			check.Replica, err = key.derive(copied.Value)
			if err != nil {
				return nil, fmt.Errorf("derive the public half of the replica of %s: %w", keyName, err)
			}
			check.Match = check.Replica == primaryPublic
		}
		checks = append(checks, check)
	}
	return checks, nil
}

// checkReplicasPhase reports whether every key's replica derives the same DID
// or address as its primary. It reads and writes nothing else, so it needs no
// confirmation.
func (d *deps) checkReplicasPhase(ctx context.Context) (*Response, error) {
	if d.replicaKeys == nil {
		return nil, fmt.Errorf("FORGE_SECRET_REPLICA_REGION is not set; this stage keeps no replicas")
	}

	keys := replicatedKeys()
	slog.Info("comparing keys with their replicas", "keys", len(keys), "replica_region", d.cfg.SecretReplicaRegion)
	checks, err := compareReplicas(ctx, d.keys, d.replicaKeys, keys)
	if err != nil {
		return nil, err
	}
	return &Response{
		Phase:         "check-replicas",
		Created:       []string{},
		ReplicaRegion: d.cfg.SecretReplicaRegion,
		ReplicaChecks: checks,
	}, nil
}
