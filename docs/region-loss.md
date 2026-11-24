# Region loss: restoring Central in eu-central-1

What becomes of prod's two KMS keys when us-east-2 is lost, how Central uses them when it is
restored in eu-central-1, what the restore must do about SSM parameters and appliances, and how to
use the key admin role that guards the keys. The rest of the
region-loss runbook (restoring Aurora in eu-central-1, rebuilding the services there, moving the
hostnames) comes with [sc-284](https://app.shortcut.com/filone/story/284).

## The keys

| Alias                        | Encrypts                                                         |
| ---------------------------- | ---------------------------------------------------------------- |
| `alias/fc-prod-aurora`       | the Aurora cluster, its snapshots and, once built, its DR copies |
| `alias/fc-prod-openbao-seal` | OpenBao's seal, and so all of OpenBao's storage in Aurora        |

Both are multi-region keys created in `terraform/envs/bootstrap/prod/us-east-2`. Each has a
replica in the DR region (`dr_region` in the constants module, eu-central-1) under the same alias.
A replica shares its primary's key material and works without it, so the replicas are the copies
that survive losing us-east-2. When us-east-2 is lost, Central is restored in eu-central-1 and runs
on the replicas.

## Restoring Central in eu-central-1

A replica encrypts and decrypts on its own: it holds the same key material and the same `mrk-…` key
id as its primary, so whatever the primary encrypted, the replica decrypts, with no call to
us-east-2. What does need the primary's region is managing the set of keys. Only a primary can be
replicated, and `UpdatePrimaryRegion` needs the current primary, so while us-east-2 is down no
replica can be promoted and no new linked key can be made. The restore needs neither.

### Aurora

Prod's Aurora data has no copy in eu-central-1 yet, so this restore is not possible today. sc-284
adds a Global Database secondary there, and the DR copies of the snapshots are not built yet. Both
will be encrypted under the replica of `alias/fc-prod-aurora`, so restoring from either will need no
snapshot copy and no re-encryption. sc-284 covers the steps.

### OpenBao

OpenBao's storage in Aurora holds its root key encrypted by the seal key. To unseal, OpenBao sends
that ciphertext to KMS `Decrypt`, and it goes on using the seal key afterwards. Any key in the
multi-region set can do this, because the ciphertext names the multi-region key id and the `awskms`
seal's `Decrypt` sends no key id of its own (go-kms-wrapping's `awskms` wrapper v2.4.0, which
OpenBao 2.6.0 uses).

1. Restore Aurora in eu-central-1 (sc-284). OpenBao's storage comes with it.
2. Apply `terraform/envs/prod/platform` with `region` set to eu-central-1. It looks up
   `alias/fc-prod-openbao-seal` in its own region, finds the replica and points the seal at it, with
   no change to the OpenBao configuration.
3. OpenBao starts, decrypts its root key through the replica and unseals with no operator step.

Before relying on a replica, check that it is enabled:

```bash
aws kms describe-key --region eu-central-1 --key-id alias/fc-prod-openbao-seal \
  --query 'KeyMetadata.[KeyState,MultiRegionConfiguration.MultiRegionKeyType]'
```

Expect `Enabled` and `REPLICA`, and the same for `alias/fc-prod-aurora`.

This has not been rehearsed yet. It needs Aurora data in the DR region, so it is part of the sc-284
rehearsal.

### Rotation while us-east-2 is down

Automatic rotation of a multi-region key runs on the primary, which then shares the new key material
with its replicas. AWS: "A replica key relies on its primary key only for key rotation and updating
the primary Region." While the us-east-2 primaries are unreachable, neither key rotates. Encryption
and decryption are unaffected.

## SSM parameters and appliances

Central's SSM parameters under `/forge-central/prod/` are not replicated, so they are lost with
us-east-2. The provision Lambda is their only writer; OpenTofu creates none. Once Aurora and OpenBao
are restored, one seed and vault run rebuilds most of them, and the rest need an operator. None of
this has been rehearsed yet; it is part of the sc-284 rehearsal.

The appliances depend on OpenBao's storage coming back with Aurora. Each region's transit key
`appliance-unseal-<region>`, its token role and the unseal tokens live there, and the key also wraps
each node's backup snapshots. Without that storage, no appliance can unseal after its next restart.

### What seed and vault rebuild

Run seed and vault as [restore-database.md](restore-database.md#8-re-run-seed-and-vault) describes.
The run writes:

- each service's `identity.did` and each wallet's `.address`, derived from the keys in Secrets
  Manager, which have replicas in eu-central-1;
- each service's `postgres-password`, as a new random value that the restored database accepts,
  because seed sets every role's password on each run;
- each `postgres-dsn` and `plc/db-creds-json`, from the new host and password;
- `hilt/vault-role-id` and `hilt/vault-secret-id`, read from the restored OpenBao or issued again;
- the delegator's and hilt's startup UCAN proofs, issued again under the same keys, with different
  bytes and CID.

The pandora DSNs are rewritten too, but the appliances get them by hand. Fetch and install each one
again as [pandora-vpn.md](pandora-vpn.md#getting-the-database-credentials-onto-the-appliance)
describes.

### hilt's partner key

`hilt/partner-key` is a random bearer token, so seed mints a new one, and every caller of hilt's
management API needs the new value. The callers are FilOne stages. Each holds one SST secret per
Forge network it calls. In the fil-one repository, `packages/backend/src/lib/service-orchestrator-registry.ts`
pairs each secret with its network's management API URL, which `sst.config.ts` sets per stage. Set
the new value in the secret of every stage whose URL is prod Central's.

### Unseal-token accessors

`appliance/<region>/unseal-token.accessor` is Central's only record of which unseal token a region's
node holds. Until it is written again, the mint plans a second token for a node that already has
one, `make onboard-appliance` refuses the region as never provisioned, and retiring the region
cannot revoke the node's token.

A node's token expires 72 hours after its last renewal. Which repair applies depends on how long the
outage lasted:

- **Under 72 hours.** The token is still live, and the node resumes renewing it on its own. With
  OpenBao's root token, find the accessor of the token created through the role
  `appliance-unseal-<region>`, and write it back:

  ```bash
  for accessor in $(bao list -format=json auth/token/accessors | jq -r '.[]'); do
    bao token lookup -format=json -accessor "$accessor" \
      | jq -r --arg a "$accessor" 'select(.data.role == "appliance-unseal-<region>") | $a'
  done
  ```

  ```bash
  aws ssm put-parameter --region eu-central-1 --type String \
    --name /forge-central/prod/appliance/<region>/unseal-token.accessor --value <accessor>
  ```

  The appliance-token dry run in
  [restore-database.md](restore-database.md#6-check-every-regions-key-and-token-before-any-vault-phase)
  then reports `token_live: true` and the action `skip`.

- **Over 72 hours.** The token has expired. The node keeps running, because it holds its key in
  memory, and fails to unseal at its next restart. Before anything restarts it, mint a new token as
  [appliance-onboarding.md](appliance-onboarding.md#minting-again) describes. The mint records the
  new accessor.

### Piri records

`appliance/<region>/piri/<host>` lists a region's Piri DIDs, one String parameter per DID, named by
the host in the Piri's did:web, with the full DID as its value. It is Central's only record of which
Piri belong to a region, and onboarding sends it to hilt as the region's node set. Setting nodes in
hilt replaces them, so an onboard run against a partial record may drop the missing Piri from
routing. Write back the full set before any onboard run for the region:

```bash
aws ssm put-parameter --region eu-central-1 --type String \
  --name /forge-central/prod/appliance/<region>/piri/<host> --value did:web:<host>
```

Take the DIDs from the appliances, and check them against sprue's provider rows and hilt's routing
policy.

`appliance/<region>/hilt-ingot-s3-proof` and its `.issuer` need nothing. The next onboard run issues
them again, and the copy on the appliance stays valid because hilt's key and hostname are unchanged.

## When us-east-2 comes back

Once the us-east-2 primaries are reachable again, there are two ways to go on.

**Keep Central in eu-central-1.** Make each eu-central-1 replica the primary of its key. The call
is guarded, so make it as the key admin role ([by hand](#by-hand)), once per key, in the current
primary's region and with the key id rather than the alias. Both keys must be `Enabled`.

```bash
aws kms update-primary-region --profile prod-kms-key-admin --region us-east-2 \
  --key-id <mrk-… key id> --primary-region eu-central-1
```

Rotation then runs from eu-central-1. Confirm it is on with `aws kms get-key-rotation-status
--region eu-central-1 --key-id <mrk-… key id>`. The us-east-2 keys become replicas, so
`terraform/envs/bootstrap/prod/us-east-2` no longer matches AWS; reworking the bootstrap roots for
the new primaries is part of sc-284.

**Move Central back to us-east-2.** The primaries hold the same key material as the replicas, so
everything written in eu-central-1 decrypts there. The keys need no change. Moving Aurora and the
services back is part of sc-284.

Moving Central to a third region later, such as another US region, needs both keys there: replicas
of the eu-central-1 keys once those are primaries, or new keys if the us-east-2 primaries are lost
for good.

### If the us-east-2 primaries are lost for good

Then the replicas can never be promoted, and neither key rotates again. Once Central is staying in
eu-central-1, migrate OpenBao's seal to a new key created there with OpenBao's seal migration (the
new seal configured beside the old one marked `disabled`, then `bao operator unseal -migrate`). The
Aurora key has the same limit; moving Aurora to a new key is part of sc-284.

## The guard

All four keys carry the same policy. Only `forge-kms-key-admin` and the account's root user may
schedule a key's deletion, disable it, change its policy, delete or move its alias, replicate it or
move its primary region. Everyone else, CI and `AdministratorAccess` included, gets
`AccessDeniedException`.

Anyone may undo a mistake with `EnableKey` or `CancelKeyDeletion`. A disabled key stops Aurora and
OpenBao at once. A key scheduled for deletion is gone for good after 30 days.

## Using the key admin role

The people who may assume it are listed in `terraform/envs/bootstrap/prod/account/main.tf`. Each
assumes it from their own `AdministratorAccess` SSO login in the prod account, in a session named
after their SSO username, which the role's trust policy requires. So the role's CloudTrail events
name the operator. It needs Identity Center: it is not a way in when SSO is down.

### Through OpenTofu

Changing a key's policy or replica goes through `terraform/envs/bootstrap/prod/us-east-2`, applied
with `key_admin` set:

```bash
aws sso login --profile <your prod SSO profile>
```

```bash
AWS_PROFILE=<your prod SSO profile> AWS_REGION=us-east-2 tofu apply -var key_admin=<your SSO username>
```

With it set, both of the root's AWS providers assume the role before planning and keep its
credentials in memory, so none reach the shell. The state backend keeps your SSO login. Without it,
an apply that changes a key's policy or replica fails with `AccessDeniedException` on `PutKeyPolicy`
or `ReplicateKey` and changes nothing. Plans and applies that leave the keys alone need no flag.

If the plan fails at `sts:AssumeRole`, you are not on the role's list, the username is not yours,
or your SSO login has expired.

### By hand

This root's state lives in us-east-2, so it cannot be applied while us-east-2 is down. For a guarded
call then, assume the role with the AWS CLI through a profile in `~/.aws/config`:

```ini
[profile prod-kms-key-admin]
source_profile    = <your prod SSO profile>
role_arn          = arn:aws:iam::811430801166:role/forge-kms-key-admin
role_session_name = <your SSO username>
```

```bash
aws kms disable-key --profile prod-kms-key-admin --region eu-central-1 --key-id <key id>
```

Once us-east-2 and its state are back, run a plan of the root and bring the code in line with
what you changed.

### If the role cannot be used

Leave `bypass_policy_lockout_safety_check` false. With it false, KMS refuses a policy that would
stop its caller from editing it again.

If the role cannot be assumed or its ARN in the policy is wrong, recreating the role under the same
name restores it, because the policy matches the role by ARN rather than by its internal id. The
root user is also exempt from the guard, but whether prod's root user can sign in and who holds its
credentials is not settled yet.
