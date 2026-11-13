# Region loss: the prod KMS keys

What to do with prod's two KMS keys when us-east-2 is lost, and how to use the break-glass role
that guards them. The rest of the region-loss runbook (promoting the Aurora secondary, rebuilding
the services, moving the hostnames) comes with
[FIL-1297](https://linear.app/filecoin-foundation/issue/FIL-1297).

## The keys

| Alias                        | Encrypts                                                  |
| ---------------------------- | --------------------------------------------------------- |
| `alias/fc-prod-aurora`       | the Aurora cluster, its snapshots and their DR copies     |
| `alias/fc-prod-openbao-seal` | OpenBao's seal, and so all of OpenBao's storage in Aurora |

Both are multi-region keys created in `terraform/envs/bootstrap/prod/us-east-2`. Each has a
replica in the DR region (`dr_region` in the constants module, eu-central-1) under the same alias.
A replica shares its primary's key material and works without it, so losing us-east-2 leaves both
keys usable in the DR region. The replicas need no promotion before use.

## The guard

All four keys carry the same policy. Only `forge-kms-break-glass` and the account's root user may
schedule a key's deletion, disable it, change its policy, delete or move its alias, replicate it or
move its primary region. Everyone else, CI and `AdministratorAccess` included, gets
`AccessDeniedException`.

Anyone may undo a mistake with `EnableKey` or `CancelKeyDeletion`. A disabled key stops Aurora and
OpenBao at once. A key scheduled for deletion is gone for good after 30 days.

## Using the break-glass role

The people who may assume it are listed in `terraform/envs/bootstrap/prod/account/main.tf`. They
use it through `terraform/envs/bootstrap/prod/us-east-2`, which changes the keys: apply that root
with `break_glass` set, from your own `AdministratorAccess` SSO login in the prod account.

```bash
aws sso login --profile <your prod SSO profile>
```

```bash
AWS_PROFILE=<your prod SSO profile> AWS_REGION=us-east-2 tofu apply -var break_glass=true
```

With the flag, both of the root's AWS providers assume the role from your SSO login before planning
and keep its credentials in memory, so none reach the shell. The state backend keeps your SSO
login. Each assumption is recorded in CloudTrail under your SSO username.

Set it when a key's policy or replica changes, since the guard refuses `PutKeyPolicy` and
`ReplicateKey` to anyone else; without it that apply fails with `AccessDeniedException` on one of
them and changes nothing. Retiring a key goes through the same root and the same flag. Plans and
applies that leave the keys alone need no flag.

If the plan fails at `sts:AssumeRole`, you are not on the role's list, or your SSO login has
expired.

Leave `bypass_policy_lockout_safety_check` false. With it false, KMS refuses a policy that would
stop its caller from editing it again.

If the role cannot be assumed or its ARN in the policy is wrong, the root user can still edit the
policy. Recreating the role under the same name also restores it, because the policy matches the
role by ARN rather than by its internal id.

## Unsealing OpenBao in the DR region

OpenBao seals with the `awskms` seal, configured by the platform module with the key the platform
root finds by `alias/fc-prod-openbao-seal`. A platform root applied in the DR region finds the
replica under that alias and passes the DR region to the seal.

The replica decrypts what the primary encrypted. The seal's `Decrypt` call sends only the ciphertext,
with no key id (go-kms-wrapping's `awskms` wrapper v2.4.0, which OpenBao 2.6.0 uses). The
ciphertext carries the multi-region key id, which the DR region's KMS resolves to the replica. So
OpenBao started in the DR region against the promoted Aurora secondary unseals with no operator
step.

1. Promote the Aurora secondary (FIL-1297).
2. Check that the replica is enabled and carries the alias:

   ```bash
   aws kms describe-key --region eu-central-1 --key-id alias/fc-prod-openbao-seal \
     --query 'KeyMetadata.[KeyState,MultiRegionConfiguration.MultiRegionKeyType]'
   ```

   Expect `Enabled` and `REPLICA`.

3. Apply the prod platform root in the DR region. The task role's seal policy names the replica's
   ARN, which the alias lookup returns.
4. Check that OpenBao reports itself unsealed:
   `curl https://<openbao host>/v1/sys/seal-status` shows `"sealed": false`.

If OpenBao stays sealed, its log names the KMS error. `AccessDeniedException` means the task role
lacks `kms:Decrypt` on the replica. `NotFoundException` means the seal points at a key ARN in
us-east-2 rather than at the replica.

This has not been rehearsed yet. It can only be tried once Aurora data is in the DR region, so it is
part of FIL-1297's rehearsal.
