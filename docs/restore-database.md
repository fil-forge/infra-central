# Restoring a stage's database to a point in time

A stage's database instance holds the data of sprue, hilt, swarf and plc, and OpenBao's storage.
Restoring it to a time T rolls all of them back together. The services lose what they wrote after T.
OpenBao loses the tokens, keys and credentials it issued after T, and the ones it revoked after T
work again. This runbook restores the instance beside the live one, swaps the names, and repairs
what the rollback breaks. It was rehearsed on dev on 2026-11-11
([FIL-1149](https://linear.app/filecoin-foundation/issue/FIL-1149)), and the times at the end come
from that run.

| Stage | Engine | Point-in-time window | Final snapshot on delete |
|---|---|---|---|
| dev | RDS PostgreSQL 16 | 1 day | none |
| staging | RDS PostgreSQL 16 | 7 days | `fc-staging-final` |
| prod | Aurora PostgreSQL 16 | 35 days | `fc-prod-final` |

The steps below are for RDS. [Aurora](#aurora-prod) lists what changes in prod. When the instance
was deleted, its automated backups went with it: restore its final snapshot with
`restore-db-instance-from-db-snapshot` and continue from step 3.

## What a restore takes back to T

Everything inside the instance returns to T. SSM, Secrets Manager, S3, DynamoDB, the chain, the
appliances and FilOne stay as they are.

| Component | After the restore | Repair |
|---|---|---|
| sprue, hilt, swarf and plc data | Providers, tenants, buckets, access keys, delegations, revocations and did:plc documents written after T are gone. Rows deleted after T are back. | Step 11 |
| A transit key created after T | Gone. Transit keys cannot be exported, so its node can never unseal again once its OpenBao restarts. The next vault phase creates a new key under the same name without warning. | Stop at step 6 |
| An unseal token minted after T | Gone, while SSM still records its accessor. A running node stays unsealed until its OpenBao restarts. | Re-mint in step 10 |
| An unseal token revoked or reissued after T | Live again, and no record names it. | Revoke in step 10 |
| An unseal token whose period ran out before the restore | Expired. | Re-mint in step 10 |
| An unseal token minted before T and renewed since | Live. us-east-9 unsealed after the drill without a re-mint. | None |
| hilt's AppRole `secret_id`, if issued after T | Unknown to OpenBao, so hilt cannot log in. | Step 8 |
| Postgres role passwords | As of T. | Step 8 |
| The master password | As of T, with no managed secret. | Step 3 |

Never restore to a time before OpenBao was initialised. The next vault phase would initialise it
again and every transit key would be gone.

## 1. Choose T

Find the latest time available:

```bash
aws rds describe-db-instances --db-instance-identifier fc-$S \
  --query 'DBInstances[0].LatestRestorableTime'
```

Then list what central issued or revoked after T. The provision Lambda logs each of these to
`/aws/lambda/fc-$S-provision`:

- `minted the unseal token`, with the region and accessor
- `revoking the previous unseal token`, with the accessor the restore brings back to life
- `replaced a stale hilt secret_id`
- the `created` list of each vault phase

Keep the list for step 10. Check `git log` on the stage's `terraform.tfvars` for regions added to
`appliance_regions` after T. A live region whose key was created after T loses its node, so choose
a later T if one exists.

## 2. Freeze

An apply during the restore can start a service mid-swap or apply against stale state. Block merges
to `main` with a temporary repository ruleset that restricts updates to the default branch and lets
repository admins bypass it through a pull request. Then disable the workflows that apply, merge or
push on their own, and wait until no run is in progress:

```bash
for wf in check-and-deploy promote auto-merge-dependabot bump-deployed-image refresh-bump-prs; do
  gh workflow disable $wf.yml --repo fil-forge/infra-central
done
gh run list --repo fil-forge/infra-central --status in_progress
```

One workflow applies all three stages, so the freeze holds staging and prod too.

## 3. Restore beside the live instance

Read the live instance's class, subnet group, security groups and parameter group from
`describe-db-instances`, and restore under a new name. The services keep running on the live
instance.

```bash
aws rds restore-db-instance-to-point-in-time \
  --source-db-instance-identifier fc-$S \
  --target-db-instance-identifier fc-$S-restore-$TS \
  --restore-time $T \
  --db-instance-class <class> --db-subnet-group-name fc-$S \
  --vpc-security-group-ids <fc-$S-database> --db-parameter-group-name <group> \
  --no-multi-az --no-publicly-accessible --storage-type gp3 --max-allocated-storage 100 \
  --copy-tags-to-snapshot --tags Key=Name,Value=fc-$S
```

RDS refuses `--manage-master-user-password` on a PostgreSQL restore, and the command takes no
Performance Insights setting. Once the restored instance is available, give it a managed secret and
wait until the secret is `active`:

```bash
aws rds modify-db-instance --db-instance-identifier fc-$S-restore-$TS \
  --manage-master-user-password --apply-immediately
aws rds describe-db-instances --db-instance-identifier fc-$S-restore-$TS \
  --query 'DBInstances[0].[DBInstanceStatus,MasterUserSecret.SecretStatus]'
```

RDS takes a first automated backup of the restored instance before it reports `available`. On dev
that took 14 minutes. `aws rds wait db-instance-available` gives up after 30 minutes, so poll the
status instead when the restore and the backup together may run longer.

## 4. Stop the services

Downtime starts here. Scale sprue, hilt, swarf, plc, the delegator and OpenBao to zero.
signing-service has no database and keeps running.

```bash
for s in sprue hilt swarf plc delegator openbao; do
  aws ecs update-service --cluster fc-$S --service fc-$S-$s --desired-count 0 >/dev/null
done
scripts/wait-services-stable.sh fc-$S
```

## 5. Swap the names

```bash
aws rds modify-db-instance --db-instance-identifier fc-$S \
  --new-db-instance-identifier fc-$S-pre-restore-$TS --apply-immediately
# wait until fc-$S-pre-restore-$TS is available
aws rds modify-db-instance --db-instance-identifier fc-$S-restore-$TS \
  --new-db-instance-identifier fc-$S --apply-immediately
# wait until fc-$S is available
```

The endpoint keeps its hostname, so every DSN in SSM reaches the restored data. Check that `fc-$S`
has the restored instance's creation time and resource id. Then scale OpenBao to 1. It unseals with
the KMS key, which the restore leaves alone, and `https://ssm.<suffix>/v1/sys/health` returns 200.

## 6. Check every region's key and token before any vault phase

For each label in the stage's `appliance_regions`, ask the provision Lambda for its token plan. The
dry run reads the transit key and whether the token on record is live, and changes nothing:

```bash
aws lambda invoke --function-name fc-$S-provision --cli-binary-format raw-in-base64-out \
  --payload '{"phase":"appliance-token","confirm":false,"region":"<region>","node_cidr":"192.0.2.1/32"}' \
  /dev/stdout
```

`no transit key` for a live region means its node is lost at its next OpenBao restart. Run no vault
phase and no apply, and either [roll back](#rolling-back-the-restore) or restore again to a later T.
`token_live: false` means the region needs a new token in step 10.

## 7. Point OpenTofu's state at the restored instance

State tracks the original instance by its resource id, and that instance now carries the
`pre-restore` name. A plan against this state updates it in place and renames it back to `fc-$S`.
Work from a checkout of `origin/main` while the freeze holds, and note the state object's version
id first; the state bucket is versioned.

```bash
cd terraform/envs/$S/platform
tofu state rm 'module.platform.module.database[0].aws_db_instance.this'
tofu import 'module.platform.module.database[0].aws_db_instance.this' fc-$S
tofu plan
```

The plan updates the instance in place and replaces nothing. On dev it turned Performance Insights
back on and added the stage tags. Three more lines changed nothing on the instance:
`engine_version` from `16.13` to `16`, which RDS resolves to 16.13, `manage_master_user_password`,
and `password_wo`. The provision Lambda's `FORGE_DB_MASTER_SECRET_ARN` and its IAM statement move
to the restored instance's secret.

## 8. Re-run seed and vault

Open a pull request that bumps `seed_trigger` and `vault_trigger` in
`terraform/envs/$S/platform/main.tf`. Re-enable `check-and-deploy.yml` so the pull request gets its
plans; the ruleset still blocks `main`. Read `plan-$S-platform`, then merge with the admin bypass.
The apply does three things:

- Seed re-applies every role password from SSM, connecting with the new master secret.
- Vault finds hilt's stored `secret_id` unknown to the restored OpenBao and issues a new one.
- `apply-$S-apps` sets each service's `desired_count` back to 1 once the platform apply passes.

On dev, seed failed with `AccessDenied` on the new master secret. The apply invoked it in the same
second it updated the IAM policy, before the policy had propagated. Re-running the failed jobs with
`gh run rerun <run> --failed` passed. Vault's invocation was already in state and did not run again.

## 9. Confirm the services

```bash
make smoke STAGE=$S
```

Downtime ends when this passes. Every task starts from zero, so each service reads its DSN, and hilt
its new `secret_id`, when it starts.

## 10. Repair appliance tokens

For a region whose token was issued after T (`token_live: false`), mint a new one and deliver it as
[appliance-onboarding.md](appliance-onboarding.md) describes:

```bash
make mint-appliance-credentials STAGE=$S REGION=<region> NODE_IP=<ip> MINT_ARGS=--reissue-unseal-token
```

For each accessor on step 1's `revoking` list, point the region's
`/forge-central/$S/appliance/<region>/unseal-token.accessor` at it, check that the dry run reports
`token_live: true`, and reissue with the same command. A reissue revokes the token on record, which
is now the revived one. On dev, a token revoked 14 minutes after T was live again after the restore.

Then each node's operator restarts its OpenBao and runs the node's smoke test from infra-nodes. A
node that stays sealed follows infra-nodes'
[recover-expired-unseal-token](https://github.com/fil-forge/infra-nodes/blob/main/docs/runbook/recover-expired-unseal-token.md).

## 11. Reconcile what lives outside the database

FilOne tenants created after T are unknown to central. The console provisions such a tenant again
on its next request, under a new did:plc identity with new keys and principals. On dev this
happened on the first bucket creation (`PUT /tenants/<id>` returned 201). Objects the tenant stored
on appliances under its old identity are no longer reachable through it.

Tenants, buckets and access keys deleted after T are back in central while FilOne no longer lists
them, and a restored access key authenticates again. Delete them again.

Revocations swarf recorded after T are lost, and those delegations are valid again. Issue them again
from FilOne.

Appliances onboarded after T are unknown to sprue. Run `make onboard-appliance` for each.

The delegator's DynamoDB tables stay as they are unless restored to T separately.

## 12. Lift the freeze and clean up

Re-enable the other workflows and delete the ruleset. Keep `fc-$S-pre-restore-$TS` until the
incident is written up, then delete it with a final snapshot named after it, which cannot collide
with `fc-$S-final`.

## Rolling back the restore

Until the step 8 merge, the original instance can come back. Stop the services, rename `fc-$S` to
`fc-$S-failed-$TS` and `fc-$S-pre-restore-$TS` back to `fc-$S`, import it into state, and scale up.
After the merge the vault phase has run against the restored data, and going back takes a second
restore.

## Aurora (prod)

- Restore with `restore-db-cluster-to-point-in-time`, naming the cluster key
  `alias/fc-prod-aurora`, and create each member with `create-db-instance`.
- Swap with `modify-db-cluster --new-db-cluster-identifier`.
- Import `module.platform.module.aurora[0].aws_rds_cluster.this` and its instances.

This variant has not been rehearsed.

## Times measured on dev, 2026-11-11

| Step | Time |
|---|---|
| Restore to T | 7 min |
| First automated backup of the restored instance | 14 min |
| Managed master password | 4 min |
| Restore in total, services still up | 28 min |
| Stop services, swap, OpenBao up | 7 min |
| Token check, state import, pull request, apply, smoke test | 30 min, 5 of them the seed re-run |
| Downtime, step 4 to step 9 | 37 min |
