# Resetting a stage's app state

`make reset-apps STAGE=dev` (or `staging`) wipes everything central's apps have
stored and keeps the platform they run on. Use it when a stage has to forget its
appliances: a node rebuilt from scratch, a node moving from one Piri to several,
or test data that is no longer worth keeping. Production refuses it, in the
script and again in the provision Lambda.

Every app service in the stage is down while it runs.

## What survives

- **The RDS instance, every role and every stored DSN.** The databases are
  dropped and recreated empty under the same owners and passwords, so the
  services connect as before and migrate their schemas on start.
- **OpenBao and its `openbao` database.** The transit keys, each appliance's
  unseal token and hilt's AppRole are untouched, so no vault phase, no new
  unseal token and no trigger bump is needed.
- **`signing-service/payer-key` and `delegator/transactor-key`.** Real funds
  live at these addresses.
- **Every service identity and the three central proofs.**
- **Each region's `unseal-token.accessor` and `hilt-ingot-s3-proof`.** hilt's key
  and the Ingot DID are unchanged, so the stored delegation still verifies and
  the node keeps its copy.

## What gets wiped

- The `sprue`, `hilt`, `swarf` and `plc` databases: providers, tenants, buckets,
  access keys, delegations, revocations and the tenants' did:plc documents.
- hilt's tenant secrets in OpenBao, under `tenant/` in the `forge-central/hilt`
  mount.
- Every item in the delegator's allow list and provider-info tables. The tables
  stay, so staging's deletion protection does not get in the way.
- Every object version in sprue's `agent-message` and `delegation` buckets.
  This is not reversible, versioning included.
- Each appliance region's Piri DIDs under `appliance/<region>/piri/`.

Each Piri whose data is wiped on the node leaves its data set on chain faulting,
with about 0.9 USDFC of the payer's lockup stranded in it. `piri init` then
creates a fresh proof set, because it looks proof sets up in its own database.
Its provider registration is found on chain by wallet address and reused.

## Procedure

Keep pushes to `main` out of the window. An apply sets each service's
`desired_count` back to 1, which can bring a service up while its database is
being dropped.

### 1. Reset the node

On the appliance host, as the node operator:

```bash
sudo scripts/host/reset-apps.sh
```

It stops the apps, drops the Ingot and Piri databases, empties their data
directories and leaves the apps stopped, so nothing on the node calls central
during the next step. See "Reset the apps on dev or staging" in infra-nodes'
[RUNBOOK](https://github.com/fil-forge/infra-nodes/blob/main/docs/RUNBOOK.md).

### 2. Reset central

```bash
make reset-apps STAGE=dev
```

The script prints what the Lambda would wipe and asks for `reset-dev` before it
changes anything. It then scales sprue, hilt, swarf, plc and the delegator to
zero, runs the `reset-apps` phase, empties the tables, buckets and Piri records,
and scales the services back up. signing-service and OpenBao keep running.

A run that fails partway says so and can be repeated from the start. Until it
completes, the app services may be at zero.

### 3. Bring the node back

Deploy the node as usual (`deploy-apps.sh`, or the reconcile timer once a change
to the node's apps lands). Each Piri runs `piri init`, which the registrar
refuses with a 403 until its DID is onboarded; the container restarts until then.

### 4. Fund new Piri wallets

A Piri that kept its key and wallet needs nothing. A new one needs its owner
wallet funded before it can register on chain; see infra-nodes' RUNBOOK.

### 5. Onboard every Piri

Once per Piri, with the proof the node produced. sprue is empty, so the proof is
required:

```bash
make onboard-appliance STAGE=dev REGION=us-east-9 \
  PIRI_DID=<from the node> \
  PIRI_URL=<from the node> \
  PIRI_PROOF=piri-proof.txt
```

The log says "returning the delegation issued earlier", because the stored
delegation survived. The node already holds it, so there is nothing to hand
over. [appliance-onboarding.md](appliance-onboarding.md#registering-the-node)
covers refusals and the proof.

### 6. Reset FilOne's tenants for the region

FilOne still records the tenant IDs central no longer has. From the fil-one
repository, run the script against every FilOne stage that provisions tenants in
the region. `--stage` is FilOne's stage name, which is not central's; for
staging's `eu-central-3`:

```bash
./bin/reset-region-provisioning.ts --stage staging --region eu-central-3 --dry-run
./bin/reset-region-provisioning.ts --stage staging --region eu-central-3
```

### 7. Confirm

```bash
make smoke STAGE=dev
```

Then run the node's own smoke test from infra-nodes.

## Appendix: rebuilding the RDS instance

When OpenBao itself is broken, wiping the apps is not enough, and the whole
instance has to go. This works on dev only, where `protect_stateful_resources =
false`. It loses OpenBao along with everything else, so the vault phase runs
again, each region needs a new unseal token, and hilt's AppRole is reissued.

1. Have a pull request open that bumps both `seed_trigger` and `vault_trigger`
   in `terraform/envs/dev/platform/main.tf`. Neither invocation re-runs on its
   own when the instance is replaced.
2. Delete the instance out of band, so Terraform state is left alone, and wait:

   ```bash
   aws rds delete-db-instance --db-instance-identifier fc-dev \
     --skip-final-snapshot --delete-automated-backups
   aws rds wait db-instance-deleted --db-instance-identifier fc-dev
   ```

3. Merge the trigger bump. `apply-dev-platform` recreates the instance, runs
   seed, waits for OpenBao and runs vault. If it fails on "waiting for openbao to
   serve", force a new OpenBao deployment and rerun the job:

   ```bash
   aws ecs update-service --cluster fc-dev --service fc-dev-openbao --force-new-deployment
   ```

4. Force a new deployment of every service, because hilt still holds the old
   secret_id, then run `make reset-apps STAGE=dev` for the stores outside RDS.
5. Mint each region's unseal token again with `make mint-appliance-token` (the
   plan says `Action: mint`), rebuild the node, and continue from step 4 of the
   procedure above.
