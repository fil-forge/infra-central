# Resetting dev's central and appliance state

infra-central#85 and infra-nodes#31 move every central service's `did:web` and
every region's Ingot `did:web` onto the hostnames in
[RFC 16](https://github.com/fil-one/RFC/blob/main/rfcs/2026-07-forge-service-identities.md).
The DID changes because the hostname changes, not because a service's signing
key is rotated, so central's `identity` parameters are never touched here.
What has to go is everything addressed to the old hostnames: the tenant,
bucket and provider data in Postgres, the delegator's DynamoDB rows, sprue's S3
objects, and every UCAN proof signed for the old audience.

AWS infra stays up throughout. Only the RDS instance, the two DynamoDB tables
and the three S3 buckets get destroyed and recreated; the VPC, the ALB, the
ECS cluster and the Route53 zones are untouched.

## What survives

- **`signing-service/payer-key` and `delegator/transactor-key`.** Real funds
  live at these addresses, and nothing in this reset deletes or rotates them.
  Check both balances before starting:

  ```bash
  aws ssm get-parameter --name /forge-central/dev/signing-service/payer-key.address
  aws ssm get-parameter --name /forge-central/dev/delegator/transactor-key.address
  ```
- **Every central service's `identity` key.** `sprue`, `hilt`, `swarf`,
  `delegator`, `signing-service`, `indexer` and `etracker` keep the private key
  they were seeded with. Their `did:web` changes on its own once the new
  hostnames are live, because the DID is derived from the hostname, not stored
  alongside the key.

## What gets wiped

- The five databases on the shared RDS instance: `sprue`, `hilt`, `swarf`,
  `plc`, `openbao`. Losing `openbao`'s database means OpenBao loses its KV
  mount, its transit engine and every region's transit key, so it needs full
  reinitialization, not just a restart.
- The delegator's two DynamoDB tables, `allow_list` and `provider_info`.
- sprue's three S3 buckets. They hold no version history, so this is not
  reversible.
- Three central proofs, addressed to hostnames that are about to stop being
  the DID: `delegator/indexing-service-proof`, `delegator/egress-tracking-proof`,
  `hilt/upload-proof`.
- Each already-onboarded region's stored delegation,
  `appliance/<region>/hilt-ingot-s3-proof`. Its audience is the region's Ingot
  DID, and that DID is changing under infra-nodes#31, so the stored copy would
  otherwise be silently reused for an audience that no longer resolves to the
  node presenting it.

Dev currently onboards one region, `us-east-9`. Repeat the per-region steps
below for any other region that shows up in `appliance_regions` in
`terraform/envs/dev/platform/terraform.tfvars` by the time this runs.

## Procedure

Run every `tofu` command from a checkout of the `new-service-identities`
branch (infra-central#85), from `terraform/envs/dev/platform`.

### 1. Destroy the data stores

```bash
tofu -chdir=terraform/envs/dev/platform destroy \
  -target=module.platform.module.database.aws_db_instance.this \
  -target=module.platform.module.storage.aws_dynamodb_table.allow_list \
  -target=module.platform.module.storage.aws_dynamodb_table.provider_info \
  -target=module.platform.module.storage.aws_s3_bucket.this
```

Dev has `protect_stateful_resources = false`, so nothing blocks this: no
deletion protection, no final snapshot, and the S3 buckets' `force_destroy`
purges their objects before the buckets themselves go.

### 2. Delete the stale proofs

Do this right before merging, in the same sitting as the merge. Dev breaks the
moment a running task restarts and can't find a proof it expects, and that's
expected — apply-apps is what puts it back together.

```bash
aws ssm delete-parameters --names \
  /forge-central/dev/delegator/indexing-service-proof \
  /forge-central/dev/delegator/egress-tracking-proof \
  /forge-central/dev/hilt/upload-proof

aws ssm delete-parameter --name /forge-central/dev/appliance/us-east-9/hilt-ingot-s3-proof
```

### 3. Force the vault phase to run again

`terraform/envs/dev/platform/main.tf`'s `module "platform"` block already sets
`seed_trigger = "3"` for this PR's proof reissue. It has no `vault_trigger`
line yet, so the vault phase — the one that reconfigures OpenBao's KV mount,
transit engine and per-region transit keys — has no reason to run again even
though OpenBao's database was just destroyed. Add one:

```hcl
  seed_trigger  = "3"
  vault_trigger = "2"
```

### 4. Merge infra-central#85

The merge's apply recreates the five Postgres databases and the DynamoDB
tables and S3 buckets destroyed in step 1 (a plain apply reconciles every
resource in the root, not just the ones a trigger touched), reissues the three
proofs and the appliance delegation deleted in step 2, reinitializes OpenBao,
and rewrites every service's hostname and task definition. `apply-platform`
updates the provision Lambda's hostname suffixes before invoking it, so the
one push is enough; `apply-apps` runs after and ends with
`wait-services-stable.sh` and a smoke test.

### 5. Force a new deployment of everything anyway

Confirms every task is running against the fresh state rather than a cached
connection or a cached DID document, regardless of which services already got
a new task definition from step 4:

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
```

### 6. Merge infra-nodes#31 and boot a new node

Follow infra-nodes' own runbook. The node's central addresses and its
OpenBao seal address both move under that PR, so a node built from the
old config can't reach the reset stage.

### 7. Re-onboard the region

```bash
make mint-appliance-token STAGE=dev REGION=us-east-9 NODE_IP=<node's Elastic IP>

make onboard-appliance STAGE=dev REGION=us-east-9 \
  PIRI_DID=<from the new node> \
  PIRI_URL=<from the new node> \
  PIRI_PROOF=piri-proof.txt \
  ONBOARD_ARGS="--proof-out ingot-proof.txt"
```

The appliance delegation parameter is gone, so this issues a fresh one rather
than returning the old one. The log line to look for is **"issued hilt's S3
delegation to the appliance"**; if it instead says "returning the delegation
issued earlier", step 2's delete didn't take and the stored copy is still
addressed to the retired Ingot DID.

### 8. Confirm

```bash
make smoke STAGE=dev
```
