# Resetting data stores for a new appliance

Run this when the dev or staging FilOne Appliance is rebuilt from scratch and central has to forget
the old node. Region retirement does not yet deregister a node from sprue and the delegator, so the
shortcut is to empty every store that holds node data and let the next apply rebuild them.

Postgres is private to the VPC and nobody holds a client for it, so the RDS
instance is deleted and recreated rather than its databases dropped. OpenBao
stores its data on that instance, so it comes back uninitialised and the vault
phase has to run again.

AWS infra stays up throughout. The VPC, the ALB, the ECS cluster, the Lambda and
the Route53 zones are untouched. The services crash-loop from the moment the
instance goes until the apply brings it back, which is fine in dev.

## What survives

- **`signing-service/payer-key` and `delegator/transactor-key`.** Real funds
  live at these addresses, and nothing here deletes or rotates them. Check both
  balances before starting:

  ```bash
  aws ssm get-parameter --name /forge-central/dev/signing-service/payer-key.address
  aws ssm get-parameter --name /forge-central/dev/delegator/transactor-key.address
  ```

- **Every central service's `identity` key and `postgres-dsn`.** The seed phase
  recreates each role on the new instance and applies the stored password
  unconditionally, so the DSNs the services already read keep working.
- **`openbao/root-token`, `openbao/recovery-keys`, `hilt/vault-secret-id`.**
  All three become stale when OpenBao's storage is wiped, and the vault phase
  overwrites each of them itself: it initialises the new OpenBao and stores the
  new root token, and it validates hilt's secret_id before reusing it, issuing a
  new one when the check fails.
- **`appliance/us-east-9/unseal-token.accessor`.** The token behind it dies
  with OpenBao. The mint script looks the accessor up, finds no token, and
  reports `action: mint`, so no `--reissue` is needed.
- **The three central proofs** under `delegator/` and `hilt/`. Their issuer and
  audience are unchanged.

## What gets wiped

- The RDS instance `fc-dev`, and with it the five databases `sprue`, `hilt`,
  `swarf`, `plc` and `openbao`, plus the master secret RDS manages.
- The delegator's two DynamoDB tables. The allow list holds the old node's Piri
  DID, and recreating both empty costs nothing.
- sprue's three S3 buckets. They hold no version history, so this is not
  reversible.
- Two SSM entries under the region's prefix: the stored delegation
  `hilt-ingot-s3-proof` with its `.issuer` sidecar, and every Piri DID recorded
  under `piri/`. The delegation would still verify, since neither hilt's key
  nor the Ingot DID changed, but the old node is gone and nothing holds the
  previous copy. Deleting it makes the onboard log "issued hilt's S3
  delegation to the appliance", which is the signal the last step checks for.

Dev & staging currently onboards one region, `us-east-9`. Repeat the per-region steps for any other
region in `appliance_regions` in `terraform/envs/dev/platform/terraform.tfvars`.

## Procedure

**Expect this to take 60-90 minutes to execute.**

Have the pull request from step 3 open and approved before step 1. Once the
instance is gone, any other push to `main` (an image bump, say) applies and
recreates it without running seed, and dev stays broken until the trigger bump
merges. Steps 1 to 4 belong in one sitting.

### 1. Delete the data stores

The `aws` CLI rather than `tofu destroy -target`. A targeted destroy also
destroys everything that depends on the target, and the provision Lambda, both
of its invocations and the OpenBao service all depend on the instance. Deleting
out of band leaves the state alone; the next plan sees the instance missing and
schedules a create. Dev has `protect_stateful_resources = false`, so no deletion
protection or final snapshot stands in the way.

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

aws rds delete-db-instance --db-instance-identifier fc-dev \
  --skip-final-snapshot --delete-automated-backups \
  --query 'DBInstance.DBInstanceStatus' --output text

for table in fc-dev-delegator-allow-list fc-dev-delegator-provider-info; do
  aws dynamodb delete-table --table-name "$table" \
    --query 'TableDescription.TableStatus' --output text
done

for bucket in agent-message delegation upload-shards; do
  aws s3 rm "s3://fc-dev-${bucket}-${ACCOUNT}" --recursive
done
```

The buckets stay; only their objects go. The instance takes several minutes to
delete, and the apply in step 4 cannot create its replacement while the old
one still exists under the same identifier:

```bash
aws rds wait db-instance-deleted --db-instance-identifier fc-dev
```

### 2. Delete the region's node records

```bash
aws ssm delete-parameters --names \
  /forge-central/dev/appliance/us-east-9/hilt-ingot-s3-proof \
  /forge-central/dev/appliance/us-east-9/hilt-ingot-s3-proof.issuer

aws ssm get-parameters-by-path --path /forge-central/dev/appliance/us-east-9/piri \
  --query 'Parameters[].Name' --output text \
  | tr '\t' '\n' | sed -e '/^None$/d' -e '/^$/d' \
  | xargs -r -n 10 aws ssm delete-parameters --names
```

Leave `unseal-token.accessor` where it is, for the reason given above.

### 3. Bump both Lambda triggers

Both `aws_lambda_invocation` resources in `terraform/modules/platform/main.tf`
re-invoke only when their input changes. Replacing the instance changes the
Lambda's environment and nothing in either input, so a plain apply would create
the instance and skip both phases: no databases, and an OpenBao that never
initialises. Bump both values in `terraform/envs/dev/platform/main.tf`:

```hcl
  seed_trigger  = "4"
  vault_trigger = "3"
```

Seed creates the five databases and roles. Vault initialises OpenBao, mounts
hilt's KV store and the transit engine, reissues hilt's AppRole credentials and
recreates the `appliance-unseal-us-east-9` transit key and policy.

State needs no repair after step 1. Every plan starts by refreshing each
resource from AWS, and one AWS reports as gone is dropped from state and planned
as a create. Confirm that from the branch once the instance has finished
deleting:

```bash
tofu -chdir=terraform/envs/dev/platform plan -input=false
```

Expect three creates (the instance and the two tables), the two invocations
replaced by the trigger bump, and one in-place update of the Lambda for the new
master secret's ARN. Anything else is worth reading before the merge applies it.

### 4. Merge

`apply-dev-platform` recreates the instance and the tables, runs seed, waits for
the OpenBao task to serve, runs vault, and the apps apply follows. Read the
`created_parameters` output in the job log: it should name only the OpenBao root
token, the recovery keys, hilt's secret_id and the transit key.

**If the platform apply fails on "waiting for openbao to serve"**, the OpenBao
task spent the outage crash-looping and ECS has backed off its restarts past the
four minutes the phase waits. Start a fresh task and re-run the failed job. A
failed invocation is not recorded in state, so the rerun retries it:

```bash
aws ecs update-service --cluster fc-dev --service fc-dev-openbao --force-new-deployment
```

### 5. Force a new deployment of everything

No task definition changed, so the apps apply rolled nothing. hilt in particular
is still running against the secret_id it read at its last start, and the other
services may hold connections from before the instance was replaced.

```bash
CLUSTER=fc-dev

aws ecs list-services --cluster "$CLUSTER" --query 'serviceArns[]' --output text \
  | tr '\t' '\n' | sed -e '/^None$/d' -e '/^$/d' \
  | xargs -n1 basename \
  | while read -r service; do
      echo "forcing new deployment: $service"
      aws ecs update-service --cluster "$CLUSTER" --service "$service" \
        --force-new-deployment --query 'service.serviceName' --output text
    done

scripts/wait-services-stable.sh "$CLUSTER"
make smoke STAGE=dev
```

### 6. Wipe out the node

_We will update this section with concrete instructions once we run the reset for the first time._

If you are resetting the dev env, the easiest way to reset the regional node is to destroy the AWS EC2 instance and create it again.

For nodes where we cannot recreate the entire machine, like the bare-metal box in Amsterdam where
our staging region runs, we need to wipe out the control & data plan, and the unseal token.

### 7. Onboard the node

Follow the onboarding guides:

- [Mint the unseal token](./appliance-onboarding.md#minting-the-unseal-token)
- [Provision the appliance platform](https://github.com/fil-forge/infra-nodes/blob/main/docs/RUNBOOK.md#4-the-platform)
- [Create onboarding request](https://github.com/fil-forge/infra-nodes/blob/main/docs/RUNBOOK.md#5-onboarding-then-the-apps)
- [Register the node](./appliance-onboarding#registering-the-node)

Hilt and Sprue cache a resolved DID document for three hours, and the Ingot's
document now publishes a new key. Restart the services to empty their caches:

```bash
aws ecs update-service --cluster fc-dev --service fc-dev-hilt --force-new-deployment
aws ecs update-service --cluster fc-dev --service fc-dev-sprue --force-new-deployment
```

Hand `ingot-proof.txt` to the node operator for `store-hilt-proof.sh`.

### 9. Confirm

```bash
make smoke STAGE=dev
```
