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
| **SSM Parameter Store, per-service prefixes**   | Each task execution role reads only `/forge/<stage>/<service>/*`. A compromised sprue task cannot read hilt's AppRole secret or the delegator's transactor key. smelt's 1Password item is all-or-nothing by comparison. |
| **OpenBao stores in Postgres, not on a volume** | Fargate has no durable local disk. Reusing the RDS instance avoids an EFS filesystem and keeps a replaced task's data intact.                                                                                           |
| **OpenBao seals with KMS**                      | There is no unseal key to store, share or leak, and no sidecar polling to apply one. A restarted task comes back ready with no operator step. smelt runs 1-of-1 Shamir with the key in 1Password.                       |
| **hilt authenticates with AppRole, not root**   | Its policy reaches only `forge/hilt/data/tenant/*`. smelt hands hilt the Vault root token and tracks that as debt.                                                                                                      |
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

## SSM parameters outlive the stage

**`terraform destroy` does not delete any secret this project generates.**

The provision Lambda creates the parameters, so Terraform has no record of them
and never removes them. That is deliberate: an accidental destroy cannot burn a
funded wallet or invalidate a DID that storage providers have already
registered against.

It also has a sharp edge worth stating plainly. **A destroyed and recreated
stage silently comes back with its previous identities and wallets.** That is
usually what you want, and it is occasionally a surprise, so check before
assuming a rebuilt stage is fresh:

```bash
aws ssm get-parameters-by-path --path /forge/dev --recursive \
  --query 'Parameters[].Name' --output text
```

To genuinely retire a stage, delete the parameters after the destroy, having
first confirmed the wallets hold no funds:

```bash
# Check the balances first. This is not reversible.
aws ssm get-parameter --name /forge/dev/signing-service/payer-key.address
aws ssm get-parameter --name /forge/dev/delegator/transactor-key.address

aws ssm get-parameters-by-path --path /forge/dev --recursive \
  --query 'Parameters[].Name' --output text \
  | xargs -n 10 aws ssm delete-parameters --names
```

## Runbook

### How each part is deployed

There is no CI/CD yet. Everything below is run by an operator from a developer
machine, against HCP Terraform for state.

| Part                   | How it is deployed today                                  |
| ---------------------- | --------------------------------------------------------- |
| `bootstrap` workspaces | `terraform apply` run locally, always                      |
| provision image        | `make publish` run locally, pushed to ECR by hand          |
| `platform` workspaces  | TODO: the deployment path is not settled yet               |
| `apps` workspaces      | TODO: the deployment path is not settled yet               |

See [Planned work](#planned-work) for the automation that would replace the
manual steps.

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
`terraform/modules/constants`.

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
account id it belongs to, and add that id to `terraform/modules/constants` if it
is not there yet. Every root reads its account id from that module, so an apply
run with credentials for the wrong account fails at plan time rather than
building a second working copy of the stage somewhere unexpected.

### Bringing up a stage

```bash
cd terraform/envs/dev/platform && terraform apply   # VPC, RDS, OpenBao, secrets
cd ../apps                     && terraform apply   # the six services
```

The platform apply is slow the first time: it waits for the OpenBao task's cold
start before it can initialise it.

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
on funds *deposited into* the FilecoinPay contract, so a freshly faucet-funded
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
PAYER=$(aws ssm get-parameter --name /forge/dev/signing-service/payer-key.address \
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
make publish && terraform apply
```

`make publish` writes the new digest into the stage's `image.auto.tfvars`, so
there is no line to edit by hand. **Commit that file.** The stage plans in HCP,
which sees only what is in version control, so an uncommitted digest is applied
nowhere.

Promoting the same image to prod is a copy of that digest into
`terraform/envs/prod/platform/terraform.tfvars`, done deliberately when the
change is ready rather than as a side effect of a build.

### Deploying a service

Change its tag in the stage's `image_tags` and apply the `apps` workspace. Dev
tracks `main`; prod pins `sha-<short>`.

### Confirming nothing was regenerated

The most important check after any apply:

```bash
terraform -chdir=terraform/envs/dev/platform output created_parameters
```

Empty means every key already existed and was reused. A non-empty list after
the first apply of a stage means something was minted; find out what before
assuming a wallet is intact.

### Rotating a service identity

Delete the parameter, then re-apply:

```bash
aws ssm delete-parameter --name /forge/dev/swarf/identity
terraform -chdir=terraform/envs/dev/platform apply
```

The new DID appears in `service_dids`. Anything that had registered the old DID
has to be told about the new one, which is why this is a deliberate act rather
than something an apply does on its own.

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
diffing. Only the framing is reproducible — raw codecs are written bare,
textual container codecs end with a newline — and that is what the tests pin.

### Rotating hilt's OpenBao credential

```bash
aws ssm delete-parameter --name /forge/dev/hilt/vault-secret-id
terraform -chdir=terraform/envs/dev/platform apply -var vault_trigger=$(date +%s)
```

The vault phase also self-heals: if a stored `secret_id` no longer
authenticates, because OpenBao's storage was rebuilt underneath it, the next run
replaces it rather than leaving hilt unable to start.

## Repository layout

```
# Go binary executed in AWS to provision DB & secrets
cmd/forge-provision/     the Lambda: phase dispatch, seeding, OpenBao, funding
internal/keygen/         Ed25519 identities, secp256k1 wallets, UCAN proofs
internal/dbinit/         idempotent role and database creation
internal/vaultinit/      OpenBao init, mounts, hilt's AppRole
internal/ssmstore/       the never-overwrite parameter store
internal/fund/           the three FilecoinPay transactions
build/                   Lambda container image
scripts/fund-payer.sh    invokes the fund phase, with a confirmation prompt

# Infra configuration
terraform/
  modules/
    network/  database/  storage/  ingress/  kms/    building blocks
    provision/  openbao/  ecs-service/
    platform/                                        composes the above
    apps/                                            the six services
    ecr/                                             forge-central/provision repo
    constants/                                       account ids, shared literals
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
AWS account without colliding: `forge-<stage>-*` resources, `/forge/<stage>/*`
parameters, and `<service>.<stage>.forge-sandbox.fil.one` hostnames.

```
envs/<stage>/platform/     VPC, RDS, S3, DynamoDB, ALB, OpenBao, provision Lambda
  main.tf                  module "platform" plus what this stage overrides
  terraform.tfvars         committed, non-secret: DNS, chain, contracts
  outputs.tf               re-exported for the apps workspace
  image.auto.tfvars        committed, written by `make publish`

envs/<stage>/apps/         the six ECS services
  main.tf                  reads platform outputs via tfe_outputs
  terraform.tfvars         committed: image tags
```

Both roots stay short because `modules/platform` and `modules/apps` hold the
wiring. That is the point of the split: a stage's root says what differs, and
nothing else can drift between stages.

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
4. Create the two HCP workspaces with those names and working directories.

Prod differs from dev inside `main.tf` rather than by being a different shape:
multi-AZ database, deletion protection on, a larger OpenBao connection budget,
and a digest pinned in `terraform.tfvars`, copied from dev when a change is
promoted rather than written by whatever was built last.

### A personal sandbox stage

Stage names are not limited to dev and prod. A sandbox stage in **Local**
execution mode runs Terraform on your machine with only state in HCP, which is
the fastest loop for iterating on the provision Lambda. It gets no PR previews:
automatic speculative plans need a VCS-connected workspace, and those require
Remote execution.

## Development

```bash
make check   # gofmt, go vet, go test, terraform fmt
make test
```

## Planned work

Deliberate compromises that need a change outside this repository.

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

### Deploy to dev automatically on merge

Landing a change here should reach the dev stage without anyone running
`terraform apply`. A workflow on merge to `main` that publishes the provision
image and then triggers the dev platform and apps workspaces in order.

The ordering is the substance: `apps` reads `platform` outputs through
`tfe_outputs`, so a run that starts both at once can plan `apps` against stale
values. HCP run triggers already model this — configuring the apps workspace to
trigger on a successful platform apply is likely simpler than orchestrating both
from Actions.

### Deploy service changes from their own repositories

Today a service is deployed by editing `image_tags` here. It should instead
happen when a commit lands on the service's own `main`.

Each of the five repos already publishes `sha-<short>` on merge, so the missing
piece is a `repository_dispatch` from those workflows into this one, carrying
the service name and the new tag, which then updates the dev stage's tag and
applies. Worth deciding whether the tag is written back to a committed file, so
that what dev is running stays visible in git, or held only in workspace
variables, which is less machinery and less legible.

Prod stays manual either way: pinned digests and a reviewable diff are the point.

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
