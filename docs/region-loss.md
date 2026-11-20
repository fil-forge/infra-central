# Region loss: the prod KMS keys

What becomes of prod's two KMS keys when us-east-2 is lost, how a rebuild uses them, and how to use
the key admin role that guards them. The rest of the region-loss runbook (restoring Aurora,
rebuilding the services, moving the hostnames) comes with
[FIL-1297](https://linear.app/filecoin-foundation/issue/FIL-1297).

## The keys

| Alias                        | Encrypts                                                  |
| ---------------------------- | --------------------------------------------------------- |
| `alias/fc-prod-aurora`       | the Aurora cluster, its snapshots and their DR copies     |
| `alias/fc-prod-openbao-seal` | OpenBao's seal, and so all of OpenBao's storage in Aurora |

Both are multi-region keys created in `terraform/envs/bootstrap/prod/us-east-2`. Each has a
replica in the DR region (`dr_region` in the constants module, eu-central-1) under the same alias.
A replica shares its primary's key material and works without it, so the replicas are the copies
that survive losing us-east-2. Central is not run in the DR region; the replicas exist so that a
rebuild can read what the keys encrypted.

## Rebuilding after losing us-east-2

Central is rebuilt in us-east-2 once it is back, or in another region. Either way, Aurora and
OpenBao are restored with the eu-central-1 replicas while us-east-2 is still down. No replica is
made ahead of time in a region Central might move to.

A replica encrypts and decrypts on its own: it holds the same key material and the same `mrk-…` key
id as its primary, so whatever the primary encrypted, the replica decrypts, with no call to
us-east-2. What does need the primary's region is managing the set of keys. Only a primary can be
replicated, and `UpdatePrimaryRegion` needs the current primary, so while us-east-2 is down no
replica can be promoted and no new linked key can be made. The rebuild needs neither.

### Aurora

Data restored from the DR region into the rebuild region is re-encrypted on the way: a snapshot
copied across regions takes a key in the target region (`--kms-key-id`). In us-east-2 that is
`alias/fc-prod-aurora`; elsewhere, any new key.

### OpenBao

OpenBao's storage in Aurora holds its root key encrypted by the seal key. To unseal, OpenBao sends
that ciphertext to KMS `Decrypt`, and it goes on using the seal key afterwards. Any key in the
multi-region set can do this, because the ciphertext names the multi-region key id and the `awskms`
seal's `Decrypt` sends no key id of its own (go-kms-wrapping's `awskms` wrapper v2.4.0, which
OpenBao 2.6.0 uses).

If us-east-2 is back with its primary intact, the platform root finds the key by alias as usual and
nothing changes. Otherwise:

1. Restore Aurora into the rebuild region (FIL-1297). OpenBao's storage comes with it.
2. Point OpenBao's seal at the eu-central-1 replica, calling KMS there from the rebuild region:

   ```hcl
   seal "awskms" {
     region     = "eu-central-1"
     kms_key_id = "<ARN of the replica of alias/fc-prod-openbao-seal>"
   }
   ```

   The task role needs `kms:Encrypt`, `kms:Decrypt` and `kms:DescribeKey` on the replica's ARN.
   The platform module sets the seal's region to the stage's and finds the key by alias in that
   region, so this needs the change FIL-1297 makes.

3. OpenBao starts, decrypts its root key through eu-central-1 and unseals with no operator step.
4. Optionally, move off eu-central-1: migrate the seal to a new key in the rebuild region with
   OpenBao's seal migration (the new seal configured beside the old one marked `disabled`, then
   `bao operator unseal -migrate`). Until then, the rebuilt Central depends on KMS in eu-central-1.

Before relying on a replica, check that it is enabled:

```bash
aws kms describe-key --region eu-central-1 --key-id alias/fc-prod-openbao-seal \
  --query 'KeyMetadata.[KeyState,MultiRegionConfiguration.MultiRegionKeyType]'
```

Expect `Enabled` and `REPLICA`, and the same for `alias/fc-prod-aurora`.

This has not been rehearsed yet. It needs Aurora data in the DR region, so it is part of FIL-1297's
rehearsal.

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
