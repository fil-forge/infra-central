# Restoring a stage's database to a point in time

A stage's database holds the data of sprue, hilt, swarf and plc, and OpenBao's storage. Restoring
it to a time T rolls all of them back together. The services lose what they wrote after T. OpenBao
loses the tokens, keys and credentials it issued after T, and the ones it revoked after T work
again. This runbook restores the database beside the live one, swaps the names, and repairs what the
rollback breaks ([FIL-1149](https://linear.app/filecoin-foundation/issue/FIL-1149)).

The steps are written for prod's Aurora cluster. Dev and staging run an RDS instance and follow
[the RDS variant](#dev-and-staging-rds) for steps 1, 3, 5, 7 and 12.

| Stage | Engine | Point-in-time window | Final snapshot on delete |
|---|---|---|---|
| prod | Aurora PostgreSQL 16, cluster `fc-prod`, members `fc-prod-1` and `fc-prod-2` | 35 days | `fc-prod-final` |
| staging | RDS PostgreSQL 16, instance `fc-staging` | 7 days | `fc-staging-final` |
| dev | RDS PostgreSQL 16, instance `fc-dev` | 1 day | none |

When the cluster was deleted, its automated backups went with it. Restore its final snapshot with
`restore-db-cluster-from-snapshot --snapshot-identifier fc-prod-final` in place of the point-in-time
restore in step 3, and continue from there.

## What a restore takes back to T

Everything inside the cluster returns to T. SSM, Secrets Manager, S3, DynamoDB, the chain, the
appliances and FilOne stay as they are.

| Component | After the restore | Repair |
|---|---|---|
| sprue, hilt, swarf and plc data | Providers, tenants, buckets, access keys, delegations, revocations and did:plc documents written after T are gone. Rows deleted after T are back. | Step 11 |
| A transit key created after T | Gone. Transit keys cannot be exported, so its node can never unseal again once its OpenBao restarts. The next vault phase creates a new key under the same name without warning. | Stop at step 6 |
| An unseal token minted after T | Gone, while SSM still records its accessor. A running node stays unsealed until its OpenBao restarts. | Re-mint in step 10 |
| An unseal token revoked or reissued after T | Live again, and no record names it. | Revoke in step 10 |
| An unseal token whose period ran out before the restore | Expired. | Re-mint in step 10 |
| An unseal token minted before T and renewed since | Live. | None |
| hilt's AppRole `secret_id`, if issued after T | Unknown to OpenBao, so hilt cannot log in. | Step 8 |
| Postgres role passwords | As of T. | Step 8 |
| The master password | As of T, with no managed secret. | Step 3 |

Never restore to a time before OpenBao was initialised. The next vault phase would initialise it
again and every transit key would be gone.

## 1. Choose T

Read the restore window from the cluster:

```bash
aws rds describe-db-clusters --db-cluster-identifier fc-prod \
  --query 'DBClusters[0].[EarliestRestorableTime,LatestRestorableTime]'
```

Then list what central issued or revoked after T. The provision Lambda logs each of these to
`/aws/lambda/fc-prod-provision`:

- `minted the unseal token`, with the region and accessor
- `revoking the previous unseal token`, with the accessor the restore brings back to life
- `replaced a stale hilt secret_id`
- the `created` list of each vault phase

Keep the list for step 10. Check `git log` on `terraform/envs/prod/platform/terraform.tfvars` for
regions added to `appliance_regions` after T. A live region whose key was created after T loses its
node, so choose a later T if one exists.

## 2. Freeze

An apply during the restore can start a service mid-swap or apply against stale state. Block merges
to `main` with a temporary repository ruleset that restricts updates to the default branch and lets
repository admins bypass it through a pull request. Then disable the workflows that apply, merge or
push on their own:

```bash
for wf in check-and-deploy promote auto-merge-dependabot bump-deployed-image refresh-bump-prs; do
  gh workflow disable $wf.yml --repo fil-forge/infra-central
done
```

Disabling a workflow leaves the runs it has already created. `check-and-deploy.yml` queues a run
behind the one in progress instead of cancelling it, so an apply can be waiting to start. List every
run that has not completed, whatever its status:

```bash
gh run list --repo fil-forge/infra-central --limit 200 --json databaseId,workflowName,status \
  --jq '.[] | select(.status != "completed") | "\(.databaseId) \(.workflowName) \(.status)"'
```

Cancel each run that has not started (`queued`, `requested`, `waiting`, `pending` or
`action_required`) with `gh run cancel <id>`. Let a run that is `in_progress` finish, because
cancelling an apply partway can leave resources and state disagreeing. Go on once the list is empty.

One workflow applies all three stages, so the freeze holds dev and staging too.

## 3. Restore beside the live cluster

Restore the cluster under a temporary name, give it two members with temporary names, and give it a
managed master secret. The services keep running on the live cluster meanwhile. Each member goes in
the zone of the live member it replaces, and its flags match what the `aurora` module sets, so the
apply in step 8 has nothing to change on it.

```bash
key="$(aws kms describe-key --key-id alias/fc-prod-aurora --query KeyMetadata.Arn --output text)"
sg="$(aws ec2 describe-security-groups --filters Name=group-name,Values=fc-prod-database \
  --query 'SecurityGroups[0].GroupId' --output text)"
aws rds restore-db-cluster-to-point-in-time \
  --source-db-cluster-identifier fc-prod --db-cluster-identifier fc-prod-restore-$TS \
  --restore-to-time $T --kms-key-id "$key" \
  --db-subnet-group-name fc-prod --vpc-security-group-ids "$sg" \
  --db-cluster-parameter-group-name fc-prod-aurora-postgresql16 \
  --copy-tags-to-snapshot --deletion-protection
aws rds wait db-cluster-available --db-cluster-identifier fc-prod-restore-$TS
for n in 1 2; do
  az="$(aws rds describe-db-instances --db-instance-identifier fc-prod-$n \
    --query 'DBInstances[0].AvailabilityZone' --output text)"
  aws rds create-db-instance --db-cluster-identifier fc-prod-restore-$TS \
    --db-instance-identifier fc-prod-restore-$TS-$n --engine aurora-postgresql \
    --db-instance-class db.r8g.large --availability-zone "$az" \
    --no-publicly-accessible --no-auto-minor-version-upgrade --promotion-tier 0 \
    --enable-performance-insights --performance-insights-retention-period 7 \
    --tags Key=Name,Value=fc-prod-$n
done
aws rds wait db-instance-available --db-instance-identifier fc-prod-restore-$TS-1
aws rds wait db-instance-available --db-instance-identifier fc-prod-restore-$TS-2
aws rds modify-db-cluster --db-cluster-identifier fc-prod-restore-$TS \
  --manage-master-user-password --apply-immediately
aws rds describe-db-clusters --db-cluster-identifier fc-prod-restore-$TS \
  --query 'DBClusters[0].[Status,MasterUserSecret.SecretStatus]'
```

The restore takes no managed-password setting, so the secret comes from the last call. Go on once
the cluster is `available` and its secret is `active`.

## 4. Stop the services

Downtime starts here. Scale sprue, hilt, swarf, plc, the delegator and OpenBao to zero.
signing-service has no database and keeps running.

```bash
for s in sprue hilt swarf plc delegator openbao; do
  aws ecs update-service --cluster fc-prod --service fc-prod-$s --desired-count 0 >/dev/null
done
scripts/wait-services-stable.sh fc-prod
```

## 5. Swap the names

The module names each member `<cluster>-<n>`, so the members are renamed along with the clusters.
Move the live members out of the way first, then both clusters, then give the restored members the
canonical names. Wait for each instance or cluster to be `available` before the next rename:

```bash
for n in 1 2; do
  aws rds modify-db-instance --db-instance-identifier fc-prod-$n \
    --new-db-instance-identifier fc-prod-pre-restore-$TS-$n --apply-immediately
done
aws rds modify-db-cluster --db-cluster-identifier fc-prod \
  --new-db-cluster-identifier fc-prod-pre-restore-$TS --apply-immediately
aws rds modify-db-cluster --db-cluster-identifier fc-prod-restore-$TS \
  --new-db-cluster-identifier fc-prod --apply-immediately
for n in 1 2; do
  aws rds modify-db-instance --db-instance-identifier fc-prod-restore-$TS-$n \
    --new-db-instance-identifier fc-prod-$n --apply-immediately
done
```

The writer and reader endpoints follow the cluster identifier and keep their hostnames, so every DSN
in SSM reaches the restored data. Check that `fc-prod` has the restored cluster's creation time and
that its members are `fc-prod-1` and `fc-prod-2`. Then scale OpenBao to 1. It unseals with its KMS
key, which the restore leaves alone, and `https://ssm.<suffix>/v1/sys/health` returns 200.

## 6. Check every region's key and token before any vault phase

For each label in prod's `appliance_regions`, ask the provision Lambda for its token plan. The dry
run reads the transit key and whether the token on record is live, and changes nothing:

```bash
aws lambda invoke --function-name fc-prod-provision --cli-binary-format raw-in-base64-out \
  --payload '{"phase":"appliance-token","confirm":false,"region":"<region>","node_cidr":"192.0.2.1/32"}' \
  /dev/stdout
```

`no transit key` for a live region means its node is lost at its next OpenBao restart. Run no vault
phase and no apply, and either [roll back](#rolling-back-the-restore) or restore again to a later T.
`token_live: false` means the region needs a new token in step 10.

## 7. Point OpenTofu's state at the restored cluster

OpenTofu tracks the cluster and its members by name, so after the swap the state already reaches the
restored cluster. Replace them in state anyway, so the state holds what was read from the restored
cluster. Work from a checkout of `origin/main` while the freeze holds, and note the state object's
version id first; the state bucket is versioned.

```bash
cd terraform/envs/prod/platform
tofu state rm 'module.platform.module.aurora[0].aws_rds_cluster.this' \
  'module.platform.module.aurora[0].aws_rds_cluster_instance.this'
tofu import 'module.platform.module.aurora[0].aws_rds_cluster.this' fc-prod
tofu import 'module.platform.module.aurora[0].aws_rds_cluster_instance.this[0]' fc-prod-1
tofu import 'module.platform.module.aurora[0].aws_rds_cluster_instance.this[1]' fc-prod-2
tofu plan
```

The plan updates resources in place and replaces nothing. On the cluster it shows
`manage_master_user_password`, the two write-forwarding flags and `master_password_wo`, which an
import leaves out and which change nothing. The provision Lambda's `FORGE_DB_MASTER_SECRET_ARN` and
its IAM statement move to the restored cluster's secret. A plan that replaces the cluster or a
member, or changes an identifier, means a step went wrong: stop and roll back.

## 8. Re-run seed and vault

Open a pull request that bumps `seed_trigger` and adds `vault_trigger = "2"` in
`terraform/envs/prod/platform/main.tf`; prod has not set `vault_trigger` before, and the module's
default is `"1"`. Re-enable `check-and-deploy.yml` so the pull request gets its plans; the ruleset
still blocks `main`. Read `plan-prod-platform`, then merge with the admin bypass. The apply does
three things:

- Seed re-applies every role password from SSM, connecting with the new master secret.
- Vault finds hilt's stored `secret_id` unknown to the restored OpenBao and issues a new one.
- `apply-prod-apps` sets each service's `desired_count` back to 1 once the platform apply passes.

Seed can fail with `AccessDenied` on the new master secret when the apply invokes it in the same
second it updates the IAM policy, before the policy has propagated. Re-run the failed jobs with
`gh run rerun <run> --failed`. Vault's invocation is already in state and does not run again.

## 9. Confirm the services

```bash
make smoke STAGE=prod
```

Downtime ends when this passes. Every task starts from zero, so each service reads its DSN, and hilt
its new `secret_id`, when it starts.

## 10. Repair appliance tokens

For a region whose token was issued after T (`token_live: false`), mint a new one and deliver it as
[appliance-onboarding.md](appliance-onboarding.md) describes:

```bash
make mint-appliance-credentials STAGE=prod REGION=<region> NODE_IP=<ip> MINT_ARGS=--reissue-unseal-token
```

For each accessor on step 1's `revoking` list, point the region's
`/forge-central/prod/appliance/<region>/unseal-token.accessor` at it, check that the dry run reports
`token_live: true`, and reissue with the same command. A reissue revokes the token on record, which
is now the revived one.

Then each node's operator restarts its OpenBao and runs the node's smoke test from infra-nodes. A
node that stays sealed follows infra-nodes'
[recover-expired-unseal-token](https://github.com/fil-forge/infra-nodes/blob/main/docs/runbook/recover-expired-unseal-token.md).

## 11. Reconcile what lives outside the database

FilOne tenants created after T are unknown to central. The console provisions such a tenant again
on its next request (`PUT /tenants/<id>` returns 201), under a new did:plc identity with new keys and
principals. Objects the tenant stored on appliances under its old identity are no longer reachable
through it.

Tenants, buckets and access keys deleted after T are back in central while FilOne no longer lists
them, and a restored access key authenticates again. Delete them again.

Revocations swarf recorded after T are lost, and those delegations are valid again. Issue them again
from FilOne.

Appliances onboarded after T are unknown to sprue. Run `make onboard-appliance` for each.

The delegator's DynamoDB tables stay as they are unless restored to T separately.

## 12. Lift the freeze and clean up

Re-enable the other workflows and delete the ruleset. Keep `fc-prod-pre-restore-$TS` until the
incident is written up. Then turn off its deletion protection, delete its two members, and delete
the cluster with a final snapshot named after it, which cannot collide with `fc-prod-final`:

```bash
aws rds modify-db-cluster --db-cluster-identifier fc-prod-pre-restore-$TS \
  --no-deletion-protection --apply-immediately
for n in 1 2; do
  aws rds delete-db-instance --db-instance-identifier fc-prod-pre-restore-$TS-$n
done
aws rds delete-db-cluster --db-cluster-identifier fc-prod-pre-restore-$TS \
  --final-db-snapshot-identifier fc-prod-pre-restore-$TS-final
```

## Rolling back the restore

Until the step 8 merge, the original cluster can come back. Stop the services, then rename in the
reverse order: the restored members to `fc-prod-failed-$TS-<n>`, the restored cluster to
`fc-prod-failed-$TS`, the original cluster back to `fc-prod`, and its members back to `fc-prod-1` and
`fc-prod-2`. Replace the cluster and members in state as in step 7, and scale up. After the merge
the vault phase has run against the restored data, and going back takes a second restore.

## Dev and staging (RDS)

Dev and staging run one RDS instance, `fc-$S`, with no members to rename. Steps 2, 4, 6 and 8 to 11
are the same with `$S` in place of `prod`. In step 8, dev bumps both triggers, and staging, which
sets no `vault_trigger` either, adds `vault_trigger = "2"` as prod does.

In step 1, read the window from the instance:

```bash
aws rds describe-db-instances --db-instance-identifier fc-$S \
  --query 'DBInstances[0].LatestRestorableTime'
```

In step 3, read the live instance's class, subnet group, security groups and parameter group from
`describe-db-instances`, and restore under a new name:

```bash
aws rds restore-db-instance-to-point-in-time \
  --source-db-instance-identifier fc-$S \
  --target-db-instance-identifier fc-$S-restore-$TS \
  --restore-time $T \
  --db-instance-class <class> --db-subnet-group-name fc-$S \
  --vpc-security-group-ids <fc-$S-database> --db-parameter-group-name <group> \
  --no-multi-az --no-publicly-accessible --storage-type gp3 --max-allocated-storage 100 \
  --copy-tags-to-snapshot --tags Key=Name,Value=fc-$S
aws rds modify-db-instance --db-instance-identifier fc-$S-restore-$TS \
  --manage-master-user-password --apply-immediately
```

RDS refuses `--manage-master-user-password` on a PostgreSQL restore, which is why it is a separate
call once the instance is available, and the restore takes no Performance Insights setting; step 8
turns it back on. RDS takes a first automated backup of the restored instance before it reports
`available`, 14 minutes on dev. `aws rds wait db-instance-available` gives up after 30 minutes, so
poll the status when the restore and the backup together may run longer.

In step 5, rename the instance aside and the restored one into place:

```bash
aws rds modify-db-instance --db-instance-identifier fc-$S \
  --new-db-instance-identifier fc-$S-pre-restore-$TS --apply-immediately
aws rds modify-db-instance --db-instance-identifier fc-$S-restore-$TS \
  --new-db-instance-identifier fc-$S --apply-immediately
```

In step 7, the import is required. OpenTofu tracks an RDS instance by its resource id, so the stale
state still points at the original under its `pre-restore` name, and a plan against it renames that
instance back to `fc-$S`:

```bash
cd terraform/envs/$S/platform
tofu state rm 'module.platform.module.database[0].aws_db_instance.this'
tofu import 'module.platform.module.database[0].aws_db_instance.this' fc-$S
tofu plan
```

On dev the plan then turned Performance Insights back on, added the stage tags, and showed three
lines that change nothing: `engine_version` `16.13` to `16`, which RDS resolves to 16.13,
`manage_master_user_password`, and `password_wo`.

In step 12, delete `fc-$S-pre-restore-$TS` with `delete-db-instance --final-db-snapshot-identifier
fc-$S-pre-restore-$TS-final`.

## Rehearsals

The Aurora steps 1, 3, 5 and 7, the apply and the rollback were rehearsed on 2026-11-12 on a
throwaway cluster built from the `aurora` module in dev's account, with two `db.r8g.large` members
and no services or OpenBao on it. A row written before T was present on the restored cluster and a
row written after T was absent, both endpoint hostnames were unchanged after the swap, and the plans
before and after the import changed resources in place only.

The whole procedure, services, OpenBao and an appliance included, was rehearsed on dev's RDS
instance on 2026-11-11. A token revoked 14 minutes after T was live again after the restore, and
us-east-9 unsealed without a re-mint. The seed failure in step 8 happened there.

| Step | Aurora, 2026-11-12 | RDS on dev, 2026-11-11 |
|---|---|---|
| Restore to T | 4 min | 7 min |
| Members, or the RDS instance's first backup | 9 min | 14 min |
| Managed master secret | 2 min | 4 min |
| Swap | 8 min | 3 min |
| Apply after the import | 2 min | 25 min with the pull request, 5 of them the seed re-run |
| Rollback renames | 8 min | not run |
| Downtime, step 4 to step 9 | not measured | 37 min |
