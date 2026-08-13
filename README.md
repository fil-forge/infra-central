# infra-central

Deployment configuration for Forge central services on AWS ECS/Fargate.

Five services plus their dependencies, across as many stages as you need:
**sprue**, **hilt**, **swarf**, **piri-signing-service** and **delegator**,
backed by a shared RDS Postgres instance and an OpenBao that also serves as the
root of trust for regional appliances.

This replaces the single-VM Docker Compose deployment in
[smelt](https://github.com/fil-forge/smelt), and carries over its secret and key
generation code with one substantial change: keys are minted inside AWS by a
Lambda rather than on an operator's laptop.

## How it fits together

```
                       ALB  (*.<stage>.forge-sandbox.fil.one)
                        │
   ┌────────┬───────────┼───────────┬──────────────┬─────────┐
 sprue    hilt        swarf     delegator   signing-service  ssm
   │        │           │           │              │      (OpenBao)
   │        └─ AppRole ─┼───────────┼──────────────┼─────────┘
   │                    │           │
   ├──────── RDS Postgres (one database per service) ────────┤
   │                    │           │
   S3              plc (internal)  DynamoDB
```

`plc` runs as a sixth service with no public hostname, matching smelt. Regional
appliances reach OpenBao at `ssm.<stage>.forge-sandbox.fil.one` to unseal at boot.

## Architecture decisions

| Decision                                        | Why                                                                                                                                                                                                                     |
| ----------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Secrets minted by a Lambda in the VPC**       | Private keys are generated where they will be used. Nothing is written to a laptop, and no key enters Terraform state: the function returns only DIDs, addresses and names.                                             |
| **SSM Parameter Store, per-service prefixes**   | Each task execution role reads only `/forge-central/<stage>/<service>/*`. A compromised sprue task cannot read hilt's AppRole secret or the delegator's transactor key. smelt's 1Password item is all-or-nothing by comparison. |
| **OpenBao stores in Postgres, not on a volume** | Fargate has no durable local disk. Reusing the RDS instance avoids an EFS filesystem and keeps a replaced task's data intact.                                                                                           |
| **OpenBao seals with KMS**                      | There is no unseal key to store, share or leak, and no sidecar polling to apply one. A restarted task comes back ready with no operator step. smelt runs 1-of-1 Shamir with the key in 1Password.                       |
| **hilt authenticates with AppRole, not root**   | Its policy reaches only `forge-central/hilt/data/tenant/*`. smelt hands hilt the Vault root token and tracks that as debt.                                                                                                      |
| **Directory per stage over shared modules**     | Each stage's root says what differs and nothing else; the shared modules stop the stages drifting apart.                                                                                                                |
| **Two workspaces per stage**                    | `platform` holds the VPC, RDS, OpenBao and ingress; `apps` holds the services. A routine image bump plans in seconds and never touches the database.                                                                    |
| **Images pinned by digest**                     | A git SHA names the last commit, not the code you just built, so it collides with itself against a dirty tree. A manifest digest is content-derived and cannot move underneath a deploy.                                |
| **S3 and DynamoDB through task roles**          | No static access keys anywhere. This is what replaces MinIO's root user and password.                                                                                                                                   |

## What each service needs

| Service              | Port | Health         | Postgres | Other                        |
| -------------------- | ---- | -------------- | -------- | ---------------------------- |
| sprue                | 8080 | `/health`      | yes      | 3 S3 buckets, plc            |
| hilt                 | 8080 | `/health`      | yes      | OpenBao, plc, calls sprue    |
| swarf                | 8080 | `/health`      | yes      | SSE firehose endpoint        |
| delegator            | 8080 | `/healthcheck` | **no**   | 2 DynamoDB tables, chain RPC |
| piri-signing-service | 7446 | `/healthcheck` | no       | chain RPC                    |
| plc                  | 3000 | `/_health`     | yes      | internal only                |

### Sharp edges

These each cost an afternoon to rediscover.

- **hilt and swarf bind `127.0.0.1` by default.** Without an explicit
  `HILT_SERVER_HOST` / `SWARF_SERVER_HOST` the health check can never pass.
- **sprue, hilt and swarf generate an ephemeral identity key when none is
  supplied**, silently changing their DID on every restart. Supplying the key
  is mandatory, not an optimisation.
- **hilt and swarf accept the identity key only as a file path**, and the
  delegator's UCAN proofs are file-only too (the inline variant panics). ECS
  injects secrets as environment variables, so the `ecs-service` module wraps
  the entrypoint to write them out before exec'ing the process.
- **Health paths disagree**: `/health`, `/healthcheck` and `/_health` all appear.
- **Migrations run in-process** via goose for sprue, hilt, swarf and plc.
  Concurrent starts race on the goose lock, so services run at
  `desired_count = 1` until someone sets the relevant `*_SKIP_MIGRATIONS`.
- **No service exposes Prometheus metrics.** Observability is JSON logs on
  stdout, collected by CloudWatch.
- **swarf's `/revocations/:since` is a long-lived SSE stream**, so the ALB idle
  timeout is raised well above its 60-second default.
- **did:web resolution goes over the public internet.** hilt resolves sprue at
  `https://sprue.<stage>.forge-sandbox.fil.one/.well-known/did.json`, so a task in a private
  subnet reaches the public ALB back out through the NAT gateway.

## What survives a destroy

**`terraform destroy` deletes no parameter this project generates.** The
provision Lambda creates them, so Terraform has no record of them and never
removes them. An accidental destroy therefore cannot burn a funded wallet or
invalidate a DID that storage providers have already registered against.

They also stay readable, which takes deliberate arrangement. SecureStrings are
encrypted under the account's AWS-managed SSM key rather than the stage's own
customer-managed key. The stage's key is destroyed with the stage, and a key in
PendingDeletion stops serving decryption at once, so tying the parameters to it
would leave every secret unreadable the moment the stage came down and would
fail the next apply that tried to rebuild it. The stage's key seals OpenBao and
nothing else, and what it protects is meant to die with the stage: OpenBao's
storage sits in the same RDS instance and goes at the same time.

So **a destroyed and recreated stage silently comes back with its previous
identities and wallets.** That is usually what you want, and it is occasionally
a surprise, so check before assuming a rebuilt stage is fresh:

```bash
aws ssm get-parameters-by-path --path /forge-central/dev --recursive \
  --query 'Parameters[].Name' --output text
```

To retire a stage, delete the parameters after the destroy, having first
confirmed the wallets hold no funds:

```bash
# Check the balances first. This is not reversible.
aws ssm get-parameter --name /forge-central/dev/signing-service/payer-key.address
aws ssm get-parameter --name /forge-central/dev/delegator/transactor-key.address

aws ssm get-parameters-by-path --path /forge-central/dev --recursive \
  --query 'Parameters[].Name' --output text \
  | xargs -n 10 aws ssm delete-parameters --names
```

## Runbook

### How each part is deployed

| Part                   | How it is deployed                                  |
| ---------------------- | --------------------------------------------------- |
| `bootstrap` workspaces | `terraform apply` run locally, always               |
| provision image        | `make publish` run locally, pushed to ECR by hand   |
| dev `platform`, `apps` | HCP applies every commit to `main`, no confirmation |

The dev stage deploys itself. Both of its workspaces are connected to this
repository, track `main`, and have auto-apply on, so a merge reaches dev without
anyone running Terraform. Plans and applies execute on HCP's runners rather than
on a laptop, which is what keeps a deploy from depending on which Terraform or
provider version an operator happens to have installed.

`apps` reads `platform` outputs through `tfe_outputs`, so ordering matters:
`platform` applies first and a run trigger starts `apps` afterwards. A merge
that touched only one of them runs only that one.

AWS credentials are never stored in a workspace. Each run assumes an IAM role
in the target account through HCP's OIDC federation, and the credentials expire
with the run.

Prod is not set up yet. It will get the same two workspaces with auto-apply off,
so a commit to `main` queues a plan an operator confirms.

See [Planned work](#planned-work) for the manual steps that remain.

### First time in an account and region

The bootstrap workspaces are always applied locally. They run rarely, once per
account and region, and they create the registry that everything else depends
on, so there is nothing for a pipeline to trigger on and no earlier apply to
create their state.

```bash
terraform -chdir=terraform/envs/bootstrap/nonprod/us-east-2 init
terraform -chdir=terraform/envs/bootstrap/nonprod/us-east-2 apply
```

This creates `forge-central/provision`, the ECR repository for the provision
Lambda image. There is one bootstrap directory per account and region, each with
its own workspace and its own repository: ECR repositories are regional, Lambda
pulls an image only from ECR in the same region as the function, and a pull from
another account needs a repository policy this project does not create. Stages
sharing an account and region share the repository and pin different digests.

Every image this project publishes to ECR lives under the `forge-central/`
prefix, one repository per image. Per-image repositories are what make per-image
push permissions, lifecycle policies, and tag immutability possible.

`make publish` pushes by digest and writes no tag, so the digest a stage pins is
the only reference to the image. That is why the repository rejects tags and
carries no expiry rule: an untagged image is indistinguishable from one a stage
is running, and Lambda does not survive having its image deleted. Prune by hand
when the image count starts to bother you.

Then fill the repository. **The provision image is built and pushed by hand from
a developer machine; nothing builds it automatically.** `make publish` needs
Docker with buildx and AWS credentials for the target account, and it creates a
`docker-container` builder on first use, because Docker Desktop's default
builder cannot push by digest and cannot cross-build for arm64.

```bash
make publish STAGE=dev
```

A stage needs nothing copied from the bootstrap output. It builds the image URL
from its own account and region, which is the only registry its Lambda can pull
from anyway; the account ids and the repository name live in
`terraform/modules/shared/constants`.

### Adding a region

```bash
cp -r terraform/envs/bootstrap/nonprod/us-east-2 terraform/envs/bootstrap/nonprod/us-west-2
```

Change both region names in the copy: the workspace name
(`forge-central-bootstrap-nonprod-us-west-2`) and the provider `region`. Create
the workspace in HCP Terraform, apply, then fill the repository:

```bash
make publish STAGE=<stage> AWS_REGION=us-west-2
```

The digest is derived from the image, not from where it is stored, so a stage in
the new region can pin the same digest an existing stage already runs.

### Adding an account

Copy a `bootstrap/<account>/` directory, point the new copy's provider at the
account id it belongs to, and add that id to
`terraform/modules/shared/constants` if it is not there yet. Every root reads
its account id from that module, so an apply run with credentials for the wrong
account fails at plan time rather than building a second working copy of the
stage somewhere unexpected.

### Bringing up a stage

Merge the stage's directories to `main`. The `platform` workspace applies the
VPC, RDS, OpenBao and the secrets; its run trigger then starts `apps`, which
applies the six services.

The first `platform` apply is slow: it waits for the OpenBao task's cold start
before it can initialise it, inside a synchronous Lambda call that Lambda caps at
15 minutes. If it times out there, start the run again — the seed phase
regenerates nothing that already exists, which is what protects funded wallets.

A new stage's first run usually needs starting by hand, from **Actions → Start
new run** in the workspace: the workspace is created after its config has already
landed, so there is no later push for HCP to react to. Everything after that
arrives on `main`.

### Funding the wallets

The seed phase mints two secp256k1 wallets and reports their addresses. Both
start empty, and nothing works until they hold funds:

```bash
terraform -chdir=terraform/envs/dev/platform output wallet_addresses
```

**Gas, for both wallets.** The delegator's transactor signs provider approvals
and the payer signs PDP operations, so each needs tFIL on Calibration or FIL on
mainnet. Faucet:
<https://faucet.calibnet.chainsafe-fil.io/>

**USDFC, for the payer only.** Faucet:
<https://forest-explorer.chainsafe.dev/faucet/calibnet_usdfc> — capped at 10
USDFC per day, which is why the amounts below stay small.

**Depositing into FilecoinPay.** USDFC sitting in the payer's wallet is not
enough. Creating a proof set locks up around 0.9 USDFC, and lockup can only draw
on funds _deposited into_ the FilecoinPay contract, so a freshly faucet-funded
wallet still fails with `InsufficientLockupFunds(..., Available=0)`.

```bash
make fund-payer STAGE=dev
```

That runs three transactions, the same ones as smelt's
`scripts/staging-fund-payer.sh`:

1. `USDFC.approve(FilecoinPay, amount)` — let FilecoinPay pull the tokens
2. `FilecoinPay.deposit(USDFC, payer, amount)` — credit the payer's account
3. `FilecoinPay.setOperatorApproval(USDFC, FWSS, true, rate, lockup, period)` —
   let warm storage lock it up

**The signing happens inside the provision Lambda, in AWS.** smelt reads the
payer key out of 1Password and signs with `cast` on the operator's machine;
doing that here would pull a funded key onto a laptop, which is the property
this deployment exists to protect. The script only invokes the Lambda.

It invokes twice. The first call reads the chain and prints what it would do,
signing nothing. You then confirm, and the second call broadcasts:

```
  Payer:          0x1B90…61ED
  Wallet balance: 10 USDFC
  Account funds:  0 USDFC

Transactions to broadcast:
  - approve: let FilecoinPay pull 3 USDFC from 0x1B90…61ED
  - deposit: credit 3 USDFC to the payer's FilecoinPay account
  - setOperatorApproval: let 0x0c68…6424 lock up to 3 USDFC at 0.1 USDFC/epoch

These transactions move real funds and cannot be undone.
Type 'fund' to proceed:
```

Amounts default to smelt's, which stay under the faucet's daily cap. Override
them per run:

```bash
make fund-payer STAGE=dev DEPOSIT=5
make fund-payer FUND_ARGS="--rate-allowance 0.2 --lockup-allowance 5"
scripts/fund-payer.sh --stage dev --deposit 3 --force-deposit
```

Terraform never invokes this phase. An apply must not move money, so funding is
always an explicit operator action.

Two preconditions are checked before anything is signed: the RPC must report the
chain id the stage expects, and the payer wallet must already hold at least the
deposit amount. Neither is recoverable by this tooling, so both fail loudly.

To read the balances without invoking anything:

```bash
PAYER=$(aws ssm get-parameter --name /forge-central/dev/signing-service/payer-key.address \
  --query Parameter.Value --output text)

cast call "$USDFC_TOKEN_ADDRESS" "balanceOf(address)(uint256)" "$PAYER" \
  --rpc-url https://api.calibration.node.glif.io/rpc/v1

cast call "$FILECOIN_PAY_ADDRESS" \
  "accounts(address,address)(uint256,uint256,uint256,uint256)" \
  "$USDFC_TOKEN_ADDRESS" "$PAYER" \
  --rpc-url https://api.calibration.node.glif.io/rpc/v1
```

### Iterating on the provision Lambda

```bash
make publish STAGE=dev
```

That writes the new digest into the stage's `image.auto.tfvars`, so there is no
line to edit by hand. **Commit that file and merge it.** The stage plans in HCP,
which sees only what is in version control, so a digest left on your machine is
applied nowhere.

Promoting the same image to prod will be a copy of that digest into
`terraform/envs/prod/platform/terraform.tfvars`, done deliberately when the
change is ready rather than as a side effect of a build.

### Deploying a service

Change its digest in the stage's `image_digests` and merge. Every stage pins
digests, dev included: HCP applies dev on every commit to `main`, and a rolling
tag would make what dev runs depend on when a task last restarted rather than on
what was merged.

### Confirming nothing was regenerated

The most important check after any apply. Read `created_parameters` from the
run's outputs in HCP, or from a shell:

```bash
terraform -chdir=terraform/envs/dev/platform output created_parameters
```

Empty means every key already existed and was reused. A non-empty list after
the first apply of a stage means something was minted; find out what before
assuming a wallet is intact.

### Smoke-testing a stage

```bash
make smoke STAGE=dev
```

Every public service is checked over public HTTPS, needing no AWS credentials.
A 200 from the health path covers the whole ingress route in one request: the
Route53 record, the wildcard certificate, the listener rule, the target group
and a task passing its container health check.

The second check is the one health cannot make. sprue, hilt and swarf mint an
ephemeral identity when no key is supplied and report themselves healthy either
way, so `/.well-known/did.json` is read and its `id` compared against
`did:web:<hostname>`. A mismatch means the service is running an identity
nothing has registered against.

The script reads `hostname_suffix` from the stage's
`platform/terraform.tfvars`, so it needs no Terraform state and no TFE token.
Services are probed concurrently: a task that accepts the connection and never
replies waits out the whole timeout, and several of those in sequence is a
minute of nothing.

Two gaps it names in its own output rather than passing over:

- **plc** has no public hostname, so nothing here reaches it.
- **piri-signing-service** takes a `did:web` but serves no document at it. It is
  the only service no other service addresses by DID, so nothing resolves it
  today.

### Rotating a service identity

Delete the parameter:

```bash
aws ssm delete-parameter --name /forge-central/dev/swarf/identity
```

Then force the seed phase to run again. A plain run will not do it: the phase is
an `aws_lambda_invocation`, which re-invokes only when its input changes, and
deleting a parameter changes nothing Terraform can see. See [Forcing a provision
phase to re-run](#forcing-a-provision-phase-to-re-run).

The new DID appears in `service_dids`, and the rotation also refreshes
`/forge-central/<stage>/<service>/identity.did`, which holds the same value for
anyone reading it without decryption rights. Anything that had registered the
old DID has to be told about the new one, which is why this is a deliberate act
rather than something an apply does on its own.

Rotating an identity that _signs_ a proof — sprue, indexer or etracker —
re-issues that proof automatically in the same apply, because the old
delegation would no longer verify against a key that does not exist.

### Why proofs are not rewritten every apply

A UCAN delegation is public but not reproducible: ucantone mints a random
16-byte nonce per delegation, so signing the same request twice produces
different bytes and a different CID. Rewriting on every apply would churn the
parameter and invalidate anything holding the previous delegation.

So proofs are written once and then left alone, and re-issued only when their
issuer key was freshly minted. smelt tracks the same dependency, skipping a
committed proof unless one of the keys behind it was regenerated that run.

The practical consequence: you cannot verify a proof by regenerating it and
diffing. Only the framing is reproducible, and that is what the tests pin: a
textual container is stored as `ucantool` writes it, trailing newline included,
while a bare DAG-CBOR delegation is stored base64-encoded.

### Why the delegator's proofs are stored base64

Every proof reaches its consumer as an environment variable that the task's
entrypoint writes to a file, and an environment variable cannot carry a NUL
byte. A bare DAG-CBOR delegation is binary and contains them, so the container
never starts and runc reports only the variable's name. The delegator's two
proofs are therefore stored base64-encoded and decoded on the way to the file,
which is what `secret_files_base64` on `modules/shared/ecs-service` is for.
hilt's proof is a `base64+gzip` container, already text, and travels as it is.

A stage seeded before this needs both parameters replaced, because the seed
phase leaves an existing proof alone:

```bash
aws ssm delete-parameter --name /forge-central/dev/delegator/indexing-service-proof
aws ssm delete-parameter --name /forge-central/dev/delegator/egress-tracking-proof
```

Then force the seed phase to run again, as when rotating an identity.

### Rotating hilt's OpenBao credential

```bash
aws ssm delete-parameter --name /forge-central/dev/hilt/vault-secret-id
```

Then force the vault phase to run again. There is no way to do that from a
remote run yet — see [Forcing a provision phase to
re-run](#forcing-a-provision-phase-to-re-run).

The vault phase also self-heals: if a stored `secret_id` no longer
authenticates, because OpenBao's storage was rebuilt underneath it, the next run
replaces it rather than leaving hilt unable to start.

## Repository layout

```
# Go binary executed in AWS to provision DB & secrets
cmd/provision/           the Lambda: phase dispatch, seeding, OpenBao, funding
internal/keygen/         Ed25519 identities, secp256k1 wallets, UCAN proofs
internal/dbinit/         idempotent role and database creation
internal/vaultinit/      OpenBao init, mounts, hilt's AppRole
internal/ssmstore/       the never-overwrite parameter store
internal/fund/           the three FilecoinPay transactions
build/                   Lambda container image
scripts/fund-payer.sh    invokes the fund phase, with a confirmation prompt
scripts/smoke-test.sh    checks a deployed stage over public HTTPS

# Infra configuration
terraform/
  modules/
    platform/                                        VPC, RDS, OpenBao, ingress
      network/  database/  storage/  ingress/        building blocks, used
      kms/  provision/  openbao/                     only by platform
    apps/                                            the six services
    shared/ecs-service/                              apps, and platform's openbao
    shared/constants/                                account ids, shared literals
    ecr/                                             forge-central/provision repo
  envs/
    bootstrap/<account>/<region>/                    one workspace per registry
    dev/platform/    dev/apps/
    prod/platform/   prod/apps/
```

## DNS

`fil.one` is served by Cloudflare and has no Route53 zone. One subdomain per AWS
account is delegated to Route53, and every stage in that account writes records
inside the zone it was given.

```
Cloudflare zone fil.one
  ├── NS forge-sandbox  ──►  Route53 zone forge-sandbox.fil.one  (non-prod account)
  │                            ├── sprue.dev.forge-sandbox.fil.one
  │                            ├── ssm.dev.forge-sandbox.fil.one
  │                            └── …any future stage, same zone
  └── NS forge          ──►  Route53 zone forge.fil.one          (production account)
                               ├── sprue.forge.fil.one
                               └── ssm.forge.fil.one
```

**Adding a stage requires no change to the DNS project.** That is the property
the layout is built around, and it is what forces two suffixes rather than one.

A delegation has to cover every stage in its account, so two accounts need two
delegation points. They cannot be nested: `sandbox.forge.fil.one` would have to
be delegated from the `forge.fil.one` zone, which lives in the production
account, putting non-prod DNS inside prod and requiring a prod change for every
non-prod stage. Sibling names under `fil.one` keep the accounts independent.

Production carries no stage label, because it has a zone to itself:
`sprue.forge.fil.one`. Non-prod stages take a label inside the shared sandbox
zone: `sprue.dev.forge-sandbox.fil.one`.

Two per-stage settings follow, and this is where they diverge:

- **`zone_name`** is the delegated Route53 zone records are written into. Every
  non-prod stage shares `forge-sandbox.fil.one`.
- **`hostname_suffix`** is what that stage's hostnames end with, which for
  non-prod includes the stage label.

The delegation lives in the DNS project, added once per workspace:

```hcl
# non-prod workspace
resource "aws_route53_zone" "forge_sandbox" {
  name = "forge-sandbox.fil.one"
}

resource "cloudflare_record" "forge_sandbox_delegation" {
  count   = 4
  zone_id = local.zone_id
  name    = "forge-sandbox"
  type    = "NS"
  content = aws_route53_zone.forge_sandbox.name_servers[count.index]
  proxied = false
}
```

with the same pair named `forge` in the prod workspace.

`proxied = false` matters: these hostnames serve `did:web` documents and
terminate their own TLS at the ALB, so Cloudflare must not sit in front of them.

**Certificates belong here, not in the DNS project.** The `ingress` module
issues `*.<hostname_suffix>`, writes the DNS validation records into the
delegated zone, and waits for validation. Two reasons it cannot be one central
certificate:

- An ALB needs its certificate in the ALB's own region. A `us-east-1`
  certificate, which is what CloudFront requires, cannot be attached.
- A wildcard covers exactly one label, so `*.forge-sandbox.fil.one` does not
  match `sprue.dev.forge-sandbox.fil.one`. Each stage needs its own.

## Stages

A stage is a directory pair under `terraform/envs/`, backed by two HCP
workspaces. Everything is namespaced by the stage name, so stages coexist in one
AWS account without colliding: `fc-<stage>-*` resources,
`/forge-central/<stage>/*` parameters, and
`<service>.<stage>.forge-sandbox.fil.one` hostnames.

`fc` is short for forge-central, this repository's own deployment (as opposed to
deployments of regional nodes). It is kept short because a target group name is
capped at 32 characters, and `<prefix>-<stage>-signing-service` has to fit
inside it. Only AWS resource names abbreviate; paths and namespaces spell
forge-central out, since nothing there is close to a length limit.

```
envs/<stage>/platform/     VPC, RDS, S3, DynamoDB, ALB, OpenBao, provision Lambda
  main.tf                  module "platform" plus what this stage overrides
  terraform.tfvars         committed, non-secret: DNS, chain, contracts
  outputs.tf               re-exported for the apps workspace
  image.auto.tfvars        committed, written by `make publish`

envs/<stage>/apps/         the six ECS services
  main.tf                  reads platform outputs via tfe_outputs
  terraform.tfvars         committed: image digests
```

Both roots stay short because `modules/platform` and `modules/apps` hold the
wiring. That is the point of the split: a stage's root says what differs, and
nothing else can drift between stages.

The module tree mirrors that split, so each workspace can name the directories
it depends on:

```
terraform/modules/
  platform/                everything the platform workspace builds
    main.tf                the wiring, calling the seven below
    network/ kms/ database/ storage/ ingress/ provision/ openbao/
  apps/                    the six ECS services
  shared/                  used by more than one workspace
    ecs-service/           apps, and openbao inside platform
    constants/             every workspace, bootstrap included
  ecr/                     bootstrap only
```

A module used by exactly one workspace lives under that workspace's composite
module. `shared/` holds the two that genuinely cross the boundary. Adding a
module therefore never means editing a workspace's trigger patterns.

Chain configuration lives in the **platform** workspace and the apps workspace
reads it from there, so a stage has one set of contract addresses rather than
two copies to keep in step. That mirrors smelt's shared `smart-contracts.env`.

### Adding a stage

```bash
cp -r terraform/envs/dev terraform/envs/staging
```

Then, in the copy:

1. Set the workspace names in both `cloud` blocks to
   `forge-central-staging-{platform,apps}`.
2. Change `stage = "dev"` to `"staging"` in `platform/main.tf`, and the `Stage`
   default tag in both roots.
3. In `platform/terraform.tfvars`, set `hostname_suffix` to
   `staging.forge-sandbox.fil.one` and leave `zone_name` alone: the zone is
   already delegated and shared by every non-prod stage, so the DNS project
   needs no change. Point the `chain` block at the network this stage
   transacts against.
4. Create the two HCP workspaces with those names and working directories, in
   Remote execution mode, connected to this repository and tracking `main`.
   Each needs:
   - `TFC_AWS_PROVIDER_AUTH` and `TFC_AWS_RUN_ROLE_ARN`, which a variable set
     supplies to every workspace in the project. Nothing else authenticates to
     AWS: the run assumes the role through OIDC and the credentials expire with
     it.
   - Trigger patterns covering the stage's own directory, the composite module
     the workspace uses, and the shared modules. On `platform`:
     `terraform/envs/staging/platform/**/*`,
     `terraform/modules/platform/**/*`, `terraform/modules/shared/**/*`. On
     `apps`, the same three with `apps` in place of `platform`. Without the
     module patterns, a module change queues no plan and the stage drifts from
     the repository without saying so. Pointing them at
     `terraform/modules/**/*` instead works but plans both workspaces on every
     module change.
   - On `apps`, a run trigger on the stage's `platform` workspace, so it never
     plans against outputs an in-flight `platform` run is about to change. Also
     turn on **Auto-apply run triggers**, which is a separate setting from
     auto-apply: without it, a `platform`-only change queues an `apps` plan that
     waits for someone to confirm it.
   - On `apps`, a sensitive `TFE_TOKEN` environment variable holding a team
     token that can read the `platform` workspace's state outputs. `tfe_outputs`
     reads them through the API as the tfe provider, and remote state sharing
     does not cover that path, so the token is what makes the read work.
5. Start the first run by hand from **Actions → Start new run**. Merges take it
   from there.

Prod will differ from dev inside `main.tf` rather than by being a different
shape: multi-AZ database, deletion protection on, a larger OpenBao connection
budget, and a digest pinned in `terraform.tfvars`, copied from dev when a change
is promoted rather than written by whatever was built last.

### A personal sandbox stage

Stage names are not limited to dev and prod. A sandbox stage in **Local**
execution mode runs Terraform on your machine with only state in HCP, which is
the fastest loop for iterating on the provision Lambda: no commit, no merge, no
run to wait for. What it costs is everything the dev stage gets from HCP —
speculative plans on pull requests, applies that cannot disagree with `main`,
and a Terraform and provider version that is the same for everyone. Use it to
iterate, not to host anything anyone depends on.

## Development

```bash
make check   # gofmt, go vet, go test, terraform fmt
make test
```

Both run offline against no deployed stage, which is why `make smoke` is
separate: it needs a stage to be up. See [Smoke-testing a
stage](#smoke-testing-a-stage).

## Planned work

Deliberate compromises that need a change outside this repository.

### Onboarding a regional appliance has no tooling

Everything the central services need is minted and wired by an apply. The first
Piri/Ingot appliance pointed at a stage needs five more things, and this
repository provides none of them. Until it does, an appliance cannot finish
`piri init`: it fails at the approval step with `403`, and if it gets past that,
uploads fail with `CandidateUnavailable` and hilt rejects every tenant in the
region.

**Three registration writes.** These are runtime state, not configuration, so no
apply creates them. smelt does each one from the operator's machine against the
box; the equivalents here have no home yet.

| What | Where it lands | Without it |
| ---- | -------------- | ---------- |
| The appliance's DID on the delegator's allow list | `fc-<stage>-delegator-allow-list` | `piri init` step 4 calls `/registrar/request-approval`, which refuses any DID not on the list with a `403` |
| `provider register <did> <url> <proof>` plus `provider weight set` against sprue | sprue's database | uploads fail with `CandidateUnavailable: no storage providers available` |
| `provider add <did> <region>` against hilt | hilt's database | hilt rejects tenant creation for the region and every `/s3/*` invocation ingot makes |

smelt implements these as `staging-allowlist-piri`, `staging-register-piri` and
`staging-register-ingot`, and its runbook is the best statement of the ordering
and the failure modes.

**Two proofs, one in each direction.** `keygen.Proofs` deliberately issues three
of smelt's five, and the seed phase could not issue the other two even if it
wanted to, because both involve a key that does not exist when a stage is
brought up:

- `piri-0-proof` — signed by the appliance's own identity key, audience sprue,
  granting `/blob/allocate`, `/blob/accept`, `/blob/replica/allocate` and
  `/pdp/info`. Central never holds that key, so this proof arrives from the
  appliance and is handed to sprue as the third argument of `provider register`.
- `hilt-ingot-s3-proof` — signed by hilt, audience ingot's `did:key`, granting
  `/s3/request/authorize` and the four `/s3/bucket/*` commands. Central holds
  hilt's key, but ingot has no did:web and its `did:key` is not known until the
  appliance is provisioned, so this one is issued on demand with the appliance's
  DID as input and returned to it.

That asymmetry is the shape of the missing tool: onboarding is a request
carrying the appliance's two DIDs and its public URL, not another idempotent
phase that mints from nothing.

**There is no shell to run the admin CLIs in.** smelt reaches sprue and hilt
with `docker compose exec`. Here both run as Fargate tasks in private subnets
and `enable_execute_command` is not set on any service, so
`aws ecs execute-command` does not work either. Three ways out, none of them chosen: turn ECS Exec on and
accept a documented human path into a task; add a Lambda alongside `provision`
that performs the writes and issues the hilt proof, reusing its SSM access to
read hilt's identity; or expose the admin operations over the ALB behind
authentication, which is the largest change and the only one that also serves a
self-service future.

The delegator's allow list is the exception and can be written today. Its table
takes a single `did` string as the hash key, so an operator with credentials for
the account writes the item directly without going near a task, once the item
shape the delegator reads has been confirmed against its store package.

**Where this belongs is the open question.** The appliance knows its own DIDs
and its operator runs its bootstrap, which argues for the appliance pulling.
Every write lands in central's tables and databases, and central holds the key
that signs the proof going back, which argues for the authority staying here. The
likely answer is both halves: the appliance presents its DIDs and URL, and
tooling in this repository performs the three writes and returns the proof.
Deciding that before the first appliance arrives is cheaper than discovering it
during one.

### hilt should authenticate to OpenBao with AWS IAM auth

hilt currently uses AppRole with a `secret_id` delivered through SSM. That works
and the credential is IAM-scoped to hilt's own parameter prefix, but it is still
a long-lived shared secret that has to be stored, rotated and kept in step with
OpenBao.

The right mechanism is OpenBao's AWS IAM auth method: the task signs an
`sts:GetCallerIdentity` request with its task-role credentials, and the role is
bound to that role ARN. No shared secret is distributed at all, nothing needs
rotating, and identity derives from the task role itself.

It needs a change in hilt: `HILT_VAULT_HASHICORP_AUTH_METHOD` accepts only
`approle` or `token` today, so its vault package needs the new auth method plus
the config value to select it.

Note that CIDR binding does not substitute for this. A Fargate task has no
stable address, so `token_bound_cidrs` on the VPC's private subnets separates
the VPC from the internet but not hilt from sprue. It is applied as a coarse
control, not as the identity boundary.

### ucantool needs an importable delegation API

The provision Lambda cannot generate the delegator's and hilt's startup proofs
until `ucantool`'s `delegate` logic is callable as a library. Today it lives in
`package cmd` behind cobra flag globals, and the CLI takes the issuer key as a
file path, which would mean writing private keys to `/tmp` to use it.

Nothing is blocked: there is no `internal/` package in the way and every
cryptographic step is already exported ucantone API. The work is a move, not a
rewrite. The proposal is a `pkg/ucandelegate` taking a signer or PEM bytes, a
`pkg/ucanctn` for the codec mapping currently duplicated in two files, and
`cmd/delegate.go` reduced to a flag binder.

One behaviour has to survive exactly: the CLI writes textual container codecs
with a trailing newline and raw codecs without, and smelt's committed proof
files reflect that.

### Publish the provision image from CI

Terraform changes reach dev on merge, but the image the Lambda runs does not.
`make publish` is still run by hand from a developer machine with credentials for
the target account, and the digest it writes has to be committed before a run
will pick it up.

A workflow on merge to `main` that publishes the image and commits the digest
would close the last manual step. Ordering needs care: the commit carrying the
new digest is what triggers the deploy, so the workflow has to publish before it
writes, and write only what it published.

### Forcing a provision phase to re-run

`aws_lambda_invocation` re-invokes only when its input changes, which is what
`seed_trigger` and `vault_trigger` in `modules/platform` exist for. Rotating an
identity or hilt's OpenBao credential needs one of them bumped.

Neither is reachable today. The stage roots do not expose them, and a VCS-driven
run takes no `-var` flags, so the only way to bump one is to edit
`envs/<stage>/platform/main.tf` and merge. Exposing both as root variables would
let an operator change a workspace variable and start a run, which is probably
the answer, but it puts a value that means "re-run the thing that mints wallets"
one text field away from anyone with write access to the workspace. Worth
deciding deliberately.

### Deploy service changes from their own repositories

Today a service is deployed by editing `image_digests` here. It should instead
happen when a commit lands on the service's own `main`.

The missing piece is a `repository_dispatch` from each service's publish
workflow into this one, carrying the service name and the digest it just pushed,
which commits that digest to the dev stage. The commit is what deploys, so dev
stays visible in git rather than in a workspace variable nobody reads.

Prod stays manual either way: a promotion is a digest copied deliberately, and a
reviewable diff is the point.

### OpenBao runs without an audit log

Nothing records who read or wrote which secret. The provision Lambda used to
enable a `file` device pointed at stdout, so the audit log landed in the task's
CloudWatch log group, but OpenBao 2.x rejects audit devices created over the
API: a file device writes to an arbitrary path and a socket device to an
arbitrary socket, which it treats as an operator's decision rather than an API
caller's.

The replacement is an `audit` stanza in the server config, which
`modules/platform/openbao` already renders at task start. Two things need
checking before it goes in. A device that cannot write makes OpenBao reject
requests, so stdout under Fargate has to be confirmed as a sink that never
blocks or fills. And declarative stanzas were not applied at first boot in
2.5.0-beta
([openbao#2168](https://github.com/openbao/openbao/issues/2168)), so 2.6.0 needs
verifying against a fresh instance rather than one that has been through a
`SIGHUP`.

### OpenBao's availability target is open

Under [fil-one/RFC#21](https://github.com/fil-one/RFC/pull/21) a regional
appliance cannot boot while central OpenBao is unreachable, though steady-state
regional reads never call it. This deployment runs a single task against a
multi-AZ database, so a task replacement is a short outage on the boot path
only. Raising it needs `ha_enabled` in the storage stanza; whether that is
warranted is the RFC's own open question.

## Related

- [smelt](https://github.com/fil-forge/smelt) — the single-VM Docker Compose
  deployment this replaces, and the source of the key generation code.
- [fil-one/RFC#21](https://github.com/fil-one/RFC/pull/21) — regional security
  and key management, which makes this OpenBao the root of trust for
  appliances.
