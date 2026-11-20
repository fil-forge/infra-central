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

Central is rebuilt in us-east-2 once it is back, or in another region. The steps for the keys do not
depend on which, and no replica is made ahead of time in a region Central might move to.

KMS limits what can be done while us-east-2 is down. Only a primary key can be replicated, and
`ReplicateKey` runs in the primary's region; `UpdatePrimaryRegion` also needs the current primary.
So with us-east-2 down, the replicas cannot be promoted and no new key in the same multi-region set
can be made in any region. Neither step is needed:

- **Aurora.** Data restored from the DR region into the rebuild region is re-encrypted on the way:
  a snapshot copied across regions takes a key in the target region (`--kms-key-id`). In us-east-2
  that is `alias/fc-prod-aurora`; elsewhere, any new key.
- **OpenBao.** The seal's ciphertext names the multi-region key id, and any key in the set decrypts
  it: the `awskms` seal's `Decrypt` sends no key id (go-kms-wrapping's `awskms` wrapper v2.4.0, which
  OpenBao 2.6.0 uses).
  - Rebuilding in us-east-2 with the primary intact, the platform root finds it by alias as usual.
  - Otherwise OpenBao unseals against the eu-central-1 replica across regions: its seal takes
    `region = "eu-central-1"` and the replica's ARN. The platform module sets the seal's region to
    the stage's, so this needs the change FIL-1297 makes. To stop depending on eu-central-1, migrate
    the seal to a key in the rebuild region afterwards.

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
