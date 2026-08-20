# infra-central

Deployment configuration for Forge central services on AWS ECS/Fargate.

Six services plus their dependencies, across as many stages as you need: five
with public hostnames — **sprue**, **hilt**, **swarf**,
**piri-signing-service** and **delegator** — and **plc**, which runs internally
with no hostname of its own, matching smelt. All of them are backed by a shared
RDS Postgres instance and an OpenBao that also serves as the root of trust for
regional appliances.

This replaces the single-VM Docker Compose deployment in
[smelt](https://github.com/fil-forge/smelt), and carries over its secret and key
generation code with one substantial change: keys are minted inside AWS by a
Lambda rather than on an operator's laptop.

## Contents

- [How it fits together](#how-it-fits-together)
- [Architecture decisions](#architecture-decisions)
- [What each service needs](#what-each-service-needs) — including [Sharp edges](#sharp-edges)
- [Repository layout](#repository-layout)
- [Stages](#stages)
- [DNS](#dns)
- [What survives a destroy](#what-survives-a-destroy)
- [Runbook](#runbook)
- [Development](#development)
- [Planned work](#planned-work)
- [Related](#related)

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

Regional appliances reach OpenBao at `ssm.<stage>.forge-sandbox.fil.one` to
unseal at boot.

`piri-signing-service` is spelled `signing-service` in AWS resource names and
SSM parameter paths; both spellings refer to the same service.

## Architecture decisions

| Decision                                        | Why                                                                                                                                                                                                                             |
| ----------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Secrets minted by a Lambda in the VPC**       | Private keys are generated where they will be used. Nothing is written to a laptop, and no key enters Terraform state: the function returns only DIDs, addresses and names.                                                     |
| **SSM Parameter Store, per-service prefixes**   | Each task execution role reads only `/forge-central/<stage>/<service>/*`. A compromised sprue task cannot read hilt's AppRole secret or the delegator's transactor key. smelt's 1Password item is all-or-nothing by comparison. |
| **OpenBao stores in Postgres, not on a volume** | Fargate has no durable local disk. Reusing the RDS instance avoids an EFS filesystem and keeps a replaced task's data intact.                                                                                                   |
| **OpenBao seals with KMS**                      | There is no unseal key to store, share or leak, and no sidecar polling to apply one. A restarted task comes back ready with no operator step. smelt runs 1-of-1 Shamir with the key in 1Password.                               |
| **hilt authenticates with AppRole, not root**   | Its policy reaches only `forge-central/hilt/data/tenant/*`. smelt hands hilt the Vault root token and tracks that as debt.                                                                                                      |
| **Directory per stage over shared modules**     | Each stage's root says what differs and nothing else; the shared modules stop the stages drifting apart.                                                                                                                        |
| **Two roots per stage**                         | `platform` holds the VPC, RDS, OpenBao and ingress; `apps` holds the services. A routine image bump plans in seconds and never touches the database.                                                                            |
| **State in S3, one bucket per account**         | The state lives in the account it describes, locked by S3 conditional writes rather than a DynamoDB table. Nothing outside AWS has to be reachable for a deploy to work.                                                        |
| **OpenTofu, and Terraform refused outright**    | A `versions.tofu` / `versions.tf` pair per root. Terraform stamps a version marker OpenTofu then reads as being from the future, so one stray `terraform apply` would lock OpenTofu out of that state.                          |
| **Images pinned by digest**                     | A git SHA names the last commit, not the code you just built, so it collides with itself against a dirty tree. A manifest digest is content-derived and cannot move underneath a deploy.                                        |
| **S3 and DynamoDB through task roles**          | No static access keys anywhere. This is what replaces MinIO's root user and password.                                                                                                                                           |

## What each service needs

| Service              | Port | Health         | Postgres | Other                        |
| -------------------- | ---- | -------------- | -------- | ---------------------------- |
| sprue                | 8080 | `/health`      | yes      | 3 S3 buckets, plc            |
| hilt                 | 8080 | `/health`      | yes      | OpenBao, plc, calls sprue    |
| swarf                | 8080 | `/health`      | yes      | plc, serves an SSE stream    |
| delegator            | 8080 | `/healthcheck` | **no**   | 2 DynamoDB tables, chain RPC |
| piri-signing-service | 7446 | `/healthcheck` | no       | chain RPC                    |
| plc                  | 3000 | `/_health`     | yes      | internal only                |

Two more names appear in the parameter store: **indexer** and **etracker**. They
are not deployed, and they get identities anyway, because the delegator
validates two UCAN proofs at startup that must be signed by their keys, exactly
as in smelt. Both are expected to become real services, so their keys are kept
rather than discarded, which is also what lets the proofs be re-signed after a
rotation.

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
  stdout, collected by CloudWatch into `/forge-central/<stage>/<service>`, and
  the provision Lambda into `/aws/lambda/fc-<stage>-provision`. Both are kept
  for 30 days by default.
- **swarf's `/revocations/:since` is a long-lived SSE stream**, so the ALB idle
  timeout is raised well above its 60-second default.
- **did:web resolution goes over the public internet.** hilt resolves sprue at
  `https://sprue.<stage>.forge-sandbox.fil.one/.well-known/did.json`, so a task in a private
  subnet reaches the public ALB back out through the NAT gateway.
- **Every plan warns that `failure_threshold` is deprecated.** Expected, and the
  alternatives are worse: AWS fixed the Cloud Map custom health check wait at
  one 30-second interval and deprecated the parameter, but leaving it out makes
  the provider create the service with no custom health config at all, after
  which every plan schedules a replacement that lands in the same state. The
  comment in `terraform/modules/shared/ecs-service/routing.tf` has the full
  story and tracks the upstream issues that would end the warning.

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
  modules/                                         the wiring; see Stages below
  envs/                                            one directory per root module
    bootstrap/<account>/account/                   state bucket, CI roles
    bootstrap/<account>/<region>/                  the image registry
    dev/platform/    dev/apps/                     applied on every push to main
    prod/platform/   prod/apps/                    committed, not deployed yet

# Deployment
.github/workflows/check-and-deploy.yml    check, then plan on a PR or apply on main
```

## Stages

A stage is a directory pair under `terraform/envs/`, backed by two state files in
the account's bucket. Everything is namespaced by the stage name, so stages coexist in one
AWS account without colliding:

- `fc-<stage>-*` resources
- `/forge-central/<stage>/*` parameters
- `<service>.<stage>.forge-sandbox.fil.one` hostnames

`fc` is short for forge-central, this repository's own deployment (as opposed to
deployments of regional nodes). It is kept short because a target group name is
capped at 32 characters, and `<prefix>-<stage>-signing-service` has to fit
inside it. Only AWS resource names abbreviate; paths and namespaces spell
forge-central out, since nothing there is close to a length limit.

Files:

```
terraform/envs/<stage>/platform/   VPC, RDS, S3, DynamoDB, ALB, OpenBao, provision Lambda
  main.tf                  module "platform" plus what this stage overrides
  terraform.tfvars         committed, non-secret: DNS, chain, contracts
  outputs.tf               re-exported for the apps root
  image.auto.tfvars        committed, written by `make publish`
  versions.tofu            OpenTofu version, S3 backend, providers
  versions.tf              refuses Terraform; OpenTofu never reads it

terraform/envs/<stage>/apps/       the six ECS services
  main.tf                  reads platform outputs via terraform_remote_state
  terraform.tfvars         committed: image digests
  versions.tofu            as above, with this root's own state key
  versions.tf              as above
```

Both roots stay short because `modules/platform` and `modules/apps` hold the
wiring. That is the point of the split: a stage's root says what differs, and
nothing else can drift between stages.

The module tree mirrors that split, so each root can name the directories
it depends on:

```
terraform/modules/
  platform/                everything the platform root builds
    main.tf                the wiring, calling the seven below
    network/ kms/ database/ storage/ ingress/ provision/ openbao/
  apps/                    the six ECS services
  shared/                  used by more than one root
    ecs-service/           apps, and openbao inside platform
    constants/             every root, bootstrap included
  ecr/                     regional bootstrap only
  tfstate/                 account bootstrap only: the state bucket
  github-actions-iam/      account bootstrap only: the two CI roles
```

A module used by exactly one root lives under that root's composite module.
`shared/` holds the two that genuinely cross the boundary. Adding a module
therefore never means editing a trigger pattern anywhere, because the workflow
applies both roots on every push rather than choosing between them by path.

Chain configuration lives in the **platform** root and the apps root
reads it from there, so a stage has one set of contract addresses rather than
two copies to keep in step. That mirrors smelt's shared `smart-contracts.env`.

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

The delegation itself lives in
[fil-one/infrastructure](https://github.com/fil-one/infrastructure) and is added
once per root: an `aws_route53_zone` for the delegated name, plus a
Cloudflare `NS` record carrying that zone's four name servers, named
`forge-sandbox` in the non-prod account and `forge` in the prod one.

Those records are created with `proxied = false`, which matters: these hostnames
serve `did:web` documents and terminate their own TLS at the ALB, so Cloudflare
must not sit in front of them.

**Certificates belong here, not in the fil-one/infrastructure project.**

The `ingress` module issues `*.<hostname_suffix>`, writes the DNS validation
records into the delegated zone, and waits for validation. Two reasons it
cannot be one central certificate:

- An ALB needs its certificate in the ALB's own region. A `us-east-1`
  certificate, which is what CloudFront requires, cannot be attached.
- A wildcard covers exactly one label, so `*.forge-sandbox.fil.one` does not
  match `sprue.dev.forge-sandbox.fil.one`. Each stage needs its own.

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

### Prerequisites

- **AWS CLI**, with credentials for the target account.
- **[OpenTofu](https://opentofu.org) 1.12 or newer**, for the bootstrap roots and
  for reading a stage's outputs. Stage applies themselves run in GitHub Actions.
  Terraform is not an alternative here and every root refuses it outright: it
  stamps a version marker into state that OpenTofu reads as being from the future,
  so one `terraform apply` would lock OpenTofu out of that state.
- **Docker with buildx**, for `make publish`.
- **Go and make**, for `make check` and `make test`.
- **[Foundry](https://getfoundry.sh)'s `cast`**, only to read chain balances by
  hand. Nothing in the deploy path needs it.

### How each part is deployed

| Part                   | How it is deployed                                             |
| ---------------------- | -------------------------------------------------------------- |
| `bootstrap` roots      | `tofu apply` run locally, always                               |
| provision image        | `make publish` run locally, pushed to ECR by hand              |
| dev `platform`, `apps` | GitHub Actions, on every push to `main`, with no approval step |

The dev stage deploys itself. `.github/workflows/check-and-deploy.yml` runs `make check` on
every pull request and every push to `main`; a pull request then plans both roots,
and a push applies them. A merge reaches dev without anyone running OpenTofu, and
the version that runs is pinned in the workflow rather than being whatever an
operator has installed.

`apps` reads `platform`'s state through `terraform_remote_state`, so ordering
matters: the `apply-apps` job waits on `apply-platform` through a `needs:` edge, so
it never plans against outputs an in-flight platform apply is about to change.
Both roots are applied on every push, even one that touched only one of them. An
empty plan costs about a minute, and it means there is no path-filter list to
forget to update when a module moves.

In a pull request the two plans run at once, and the apps plan is computed against
the *last applied* platform state rather than against this pull request's platform
plan. A change to a platform output that apps consumes therefore shows its real
apps plan only after platform applies.

AWS credentials are never stored. Each job assumes an IAM role in the target
account through GitHub's OIDC federation, and the credentials expire with the job.
There are two roles, and the split matters: GitHub runs the workflow file from a
pull request's own head, so the role a plan job uses can describe infrastructure
and read nothing, and the role that can change anything is reachable only from
`refs/heads/main`. See `terraform/modules/github-actions-iam`.

Prod is not deployed yet: `terraform/envs/prod/` is committed and neither of its
bootstrap roots has ever been applied. No workflow names it, because its
`terraform.tfvars` still carries `REPLACE_ME` contract addresses.

See [Planned work](#planned-work) for the manual steps that remain.

### First time in an account and region

The bootstrap roots are always applied locally. They run rarely, they create the
things everything else depends on, and so there is nothing for a pipeline to
trigger on and no earlier apply to have created their state.

They come in two kinds, and the split is what keeps the second region cheap:

- `bootstrap/<account>/account/` — the **state bucket** every other root in the
  account keeps its state in, and the two **CI roles** GitHub Actions assumes to
  plan and apply the stages. One per account. A bucket name is global and IAM is
  not regional, so a second region must not create these again.
- `bootstrap/<account>/<region>/` — `forge-central/provision`, the **ECR
  repository** for the provision Lambda image. One per account *and* region:
  Lambda pulls an image only from ECR in the same region as the function, and a
  pull from another account needs a repository policy this project does not
  create. Stages sharing an account and region share the repository and pin
  different digests.

One thing has to exist before the account root can be applied, and nothing here
creates it: the **GitHub OIDC provider**,
`https://token.actions.githubusercontent.com`. It is one per account and shared
with every other repository that deploys into that account, so
`modules/github-actions-iam` reads it as a data source rather than owning it —
creating it here would fail for the second repository to try, and a destroy would
lock the first one out of its own CI.

Both accounts this project uses already have it, so this matters only for an
account nobody has deployed to from GitHub Actions before. Check:

```bash
aws iam list-open-id-connect-providers \
  --query "OpenIDConnectProviderList[?contains(Arn, 'token.actions.githubusercontent.com')]"
```

If that comes back empty, create it before applying the account root, or the
apply that makes the CI roles fails on the lookup with `NoSuchEntity`:

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com
```

`sts.amazonaws.com` is the audience `aws-actions/configure-aws-credentials`
requests when the workflow does not override it, and it is what both trust
policies require in their `aud` condition. Omit it from the client id list and
every `sts:AssumeRoleWithWebIdentity` call is rejected. No `--thumbprint-list`:
AWS no longer validates one for this provider.

The account root is the awkward one: its own backend points at the bucket it
creates, so the first apply in a fresh account cannot use that backend. Run it
against a local backend once, then move its state into the bucket it just made.
`.gitignore` already ignores `*_override.tf`, so the override cannot be committed
by accident:

```bash
cd terraform/envs/bootstrap/nonprod/account

printf 'terraform {\n  backend "local" {}\n}\n' > backend_override.tf
tofu init
tofu apply -target=module.tfstate    # the bucket, and nothing else yet

rm backend_override.tf
tofu init -migrate-state             # local state moves into the bucket
rm -f terraform.tfstate terraform.tfstate.backup

tofu apply                           # the CI roles
```

Note the two role ARNs it prints. `.github/workflows/check-and-deploy.yml` names them
literally, so if they differ from what is there, the workflow needs updating.

Every root after this one is ordinary — its backend block points at a bucket that
now exists — including the regional bootstrap beside it:

```bash
cd ../us-east-2
tofu init
tofu apply                           # the image registry
```

Every image this project publishes to ECR lives under the `forge-central/`
prefix, one repository per image. Per-image repositories are what make per-image
push permissions, lifecycle policies, and tag immutability possible.

Then fill the repository. **The provision image is built and pushed by hand from
a developer machine; nothing builds it automatically.** `make publish` needs
Docker with buildx and AWS credentials for the target account, and it creates a
`docker-container` builder on first use, because Docker Desktop's default
builder cannot push by digest and cannot cross-build for arm64.

```bash
make publish STAGE=dev
```

It pushes by digest and writes no tag, so the digest a stage pins is the only
reference to the image. That is why the repository rejects tags and carries no
expiry rule: an untagged image is indistinguishable from one a stage is running,
and Lambda does not survive having its image deleted. Prune by hand when the
image count starts to bother you.

A stage needs nothing copied from the bootstrap output. It builds the image URL
from its own account and region, which is the only registry its Lambda can pull
from anyway; the account ids and the repository name live in
`terraform/modules/shared/constants`.

### Adding a region

```bash
cp -r terraform/envs/bootstrap/nonprod/us-east-2 terraform/envs/bootstrap/nonprod/us-west-2
```

Change two things in the copy: the `region` in the provider block, and the `key`
in the `backend "s3"` block in `versions.tofu` (`bootstrap/us-west-2.tfstate`).

Leave the backend's `region` at `us-east-2`. It names the region the *state
bucket* is in, not the region this root deploys into, and the bucket is one per
account — created by `bootstrap/nonprod/account/`, which a regional copy does not
touch. Pointing it at `us-west-2` makes `tofu init` fail against a bucket that is
sitting right there.

Nothing else needs changing, and nothing needs deleting: the account-scoped
resources are not in this directory to begin with. So there is no bootstrap dance
here — `tofu init` works immediately, because the bucket already exists:

```bash
cd terraform/envs/bootstrap/nonprod/us-west-2
tofu init
tofu apply
```

Then fill the repository:

```bash
make publish STAGE=<stage> AWS_REGION=us-west-2
```

The digest is derived from the image, not from where it is stored, so a stage in
the new region can pin the same digest an existing stage already runs.

### Adding an account

Copy a `bootstrap/<account>/` directory, both the `account/` root and the
regional one beside it. In the copies, point each provider at the account id it
belongs to, set the bucket name in `account/main.tf` and in both `versions.tofu`
backend blocks, and add that id to `terraform/modules/shared/constants` if it is
not there yet. Confirm the account has the GitHub OIDC provider, which nothing
here creates — see [First time in an account and
region](#first-time-in-an-account-and-region) — then apply `account/` with the
greenfield procedure there, and the regional root after it.

Every root reads its account id from that module, so an apply run with
credentials for the wrong account fails at plan time rather than building a second
working copy of the stage somewhere unexpected.

### Adding a stage

```bash
cp -r terraform/envs/dev terraform/envs/staging
```

Then, in the copy:

1. Set the `key` in both `versions.tofu` files to `staging/platform.tfstate` and
   `staging/apps.tfstate`, and the `key` in the apps root's
   `terraform_remote_state` block to match the platform one. The bucket is
   already right: it is per account, and staging shares the non-prod account.
2. Change `stage = "dev"` to `"staging"` in `platform/main.tf`, and the `Stage`
   default tag in both roots.
3. In `platform/terraform.tfvars`, set `hostname_suffix` to
   `staging.forge-sandbox.fil.one` and leave `zone_name` alone: the zone is
   already delegated and shared by every non-prod stage, so the DNS project
   needs no change. Point the `chain` block at the network this stage
   transacts against.
4. Add the stage to `.github/workflows/check-and-deploy.yml`: two more entries in
   the `plan` matrix, named `staging-platform` and `staging-apps`, and two more
   apply jobs copied from dev's, with `apply-staging-apps` needing
   `apply-staging-platform`.
5. Add `"staging"` to `state_key_prefixes` on the `github_actions_iam` module in
   `terraform/envs/bootstrap/nonprod/account/main.tf` and apply that root. The
   CI roles are granted the state keys they may touch by prefix, so without this
   the stage's first run fails reading its own state.
6. Update the branch protection rule on `main`. The new stage adds two required
   checks, `plan-staging-platform` and `plan-staging-apps`, and a rule that does
   not name them will merge a pull request whose staging plan failed.
7. Merge. The workflow applies both roots on the same push, in order.

Prod will differ from dev inside `main.tf` rather than by being a different
shape: multi-AZ database, deletion protection on, a larger OpenBao connection
budget, and a digest pinned in `terraform.tfvars`, copied from dev when a change
is promoted rather than written by whatever was built last. It will also want a
gated apply rather than dev's automatic one — see [Planned
work](#planned-work).

### Bringing up a stage

Merge the stage's directories to `main`. The `platform` root applies the VPC, RDS,
OpenBao and the secrets; the `apply-apps` job then runs, applying the six
services.

The first `platform` apply is slow: it waits for the OpenBao task's cold start
before it can initialise it, inside a synchronous Lambda call that Lambda caps at
15 minutes. If it times out there, re-run the job — the seed phase regenerates
nothing that already exists, which is what protects funded wallets.

Nothing needs starting by hand. The push that adds the stage's directories is the
same push the workflow acts on, so there is no gap between the configuration
landing and the first apply.

### A personal sandbox stage

Stage names are not limited to dev and prod. Copy `envs/dev` to `envs/<you>`, give
it its own state key in the same bucket, and apply it from your machine — no
commit, no merge, no workflow run to wait for, which is the fastest loop for
iterating on the provision Lambda. Leave it out of `check-and-deploy.yml`; that is what
makes it yours.

What it costs is everything the dev stage gets from the workflow: a plan on every
pull request, applies that cannot disagree with `main`, and an OpenTofu and
provider version that is the same for everyone. Use it to iterate, not to host
anything anyone depends on.

### Funding the wallets

The seed phase mints two secp256k1 wallets and reports their addresses. Both
start empty, and nothing works until they hold funds:

```bash
tofu -chdir=terraform/envs/dev/platform output wallet_addresses
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

**The signing happens inside the `provision` Lambda, in AWS.**

The script invokes the Lambda twice. The first call reads the chain and prints
what it would do, signing nothing. You then confirm, and the second call
broadcasts.

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
line to edit by hand. **Commit that file and merge it.** The stage is planned by a
workflow, which sees only what is in version control, so a digest left on your
machine is applied nowhere.

Promoting the same image to prod will be a copy of that digest into
`terraform/envs/prod/platform/terraform.tfvars`, done deliberately when the
change is ready rather than as a side effect of a build.

### Deploying a service

Change its digest in the stage's `image_digests` and merge. Every stage pins
digests, dev included: dev is applied on every push to `main`, and a rolling tag
would make what dev runs depend on when a task last restarted rather than on what
was merged.

For dev, hilt does this itself. Its publish workflow dispatches a
`bump-deployed-image` event carrying the digest it just pushed, and
[`bump-deployed-image.yml`](.github/workflows/bump-deployed-image.yml) opens a
pull request that changes the one line, with auto-merge enabled so the deploy
lands as soon as the required checks pass. Those pull requests come from the
`fil-forge-bot` GitHub App on the branch `bot/bump-<service>-image-dev`, one
branch per service, so a second publish updates the open request instead of
stacking a stale one beside it.

The same workflow bumps any of the six services on demand:

```bash
gh workflow run bump-deployed-image.yml -R fil-forge/infra-central \
  -f service=sprue -f digest="$(crane digest ghcr.io/fil-forge/sprue:main)"
```

### Confirming nothing was regenerated

The most important check after any apply. Read `created_parameters` from the
`apply-platform` job's log, or from a shell:

```bash
tofu -chdir=terraform/envs/dev/platform output created_parameters
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

#### Why proofs are not rewritten every apply

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

#### Why the delegator's proofs are stored base64

Every proof reaches its consumer as an environment variable that the task's
entrypoint writes to a file, and an environment variable cannot carry a NUL
byte. A bare DAG-CBOR delegation is binary and contains them, so the container
never starts and runc reports only the variable's name. The delegator's two
proofs are therefore stored base64-encoded and decoded on the way to the file,
which is what `secret_files_base64` on `modules/shared/ecs-service` is for.
hilt's proof is a `base64+gzip` container, already text, and travels as it is.

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

## Development

```bash
make check   # gofmt, go vet, go test, tofu fmt
make test    # go test alone, for the inner loop
```

Both run offline against no deployed stage, which is why `make smoke` is
separate: it needs a stage to be up. See [Smoke-testing a
stage](#smoke-testing-a-stage).

### Dependency updates

Dependabot opens the pull requests, `.github/dependabot.yml` says which and how
often, and
[`auto-merge-dependabot.yml`](.github/workflows/auto-merge-dependabot.yml)
merges the ones that are minor or patch bumps. The merge is squashed and armed
through `fil-forge-bot`, so `main` moves only after `make check` and both plans
have passed, and the push that lands applies dev the same way any other merge
to `main` does.

A major bump stays open for someone to read. So does a group whose highest
change is a major, and so does any Dependabot branch that carries a commit
Dependabot did not write.

## Planned work

Deliberate compromises and open questions. Some need a change outside this
repository; the rest are work that has not been done here yet.

### Prod will need a gated apply

Dev applies on merge with no confirmation, which is the point of a dev stage. Prod
should not: an apply there wants a plan someone has read and approved.

The shape is a GitHub Environment with required reviewers on the prod apply jobs,
which turns the same workflow into plan-then-approve-then-apply without changing
how dev behaves. Worth doing in the same change that first stands prod up, because
a gate nobody has exercised is not a gate.

### The apply role's policy is only as narrow as the last failure

`modules/github-actions-iam/permissions_for_apply.tf` grants write actions per service rather than
`AdministratorAccess`, and its IAM writes are confined to `fc-*` role names. It is
still service-wide (`ec2:*`, `ecs:*`) where enumerating every action would churn
on every provider upgrade.

The plan role is the one that is genuinely tight, because a pull request chooses
what the plan job runs. Narrowing the apply role further is worth doing, but it
buys less: a push to `main` has already been reviewed.

### Automated post-deploy checks

After Terraform applies changes, run the smoke tests to verify that the stage is up and running
correctly.

### Onboarding a regional appliance has no tooling

Everything the central services need is minted and wired by an apply. The first
Piri/Ingot appliance pointed at a stage needs five more things, and this
repository provides none of them. Until it does, an appliance cannot finish
`piri init`: it fails at the approval step with `403`, and if it gets past that,
uploads fail with `CandidateUnavailable` and hilt rejects every tenant in the
region.

**Three registration writes.**

These are runtime state, not configuration, so no
apply creates them. smelt does each one from the operator's machine against the
box; the equivalents here have no home yet.

| What                                                                             | Where it lands                    | Without it                                                                                                 |
| -------------------------------------------------------------------------------- | --------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| The appliance's DID on the delegator's allow list                                | `fc-<stage>-delegator-allow-list` | `piri init` step 4 calls `/registrar/request-approval`, which refuses any DID not on the list with a `403` |
| `provider register <did> <url> <proof>` plus `provider weight set` against sprue | sprue's database                  | uploads fail with `CandidateUnavailable: no storage providers available`                                   |
| `provider add <did> <region>` against hilt                                       | hilt's database                   | hilt rejects tenant creation for the region and every `/s3/*` invocation ingot makes                       |

smelt ([smelt#11](https://github.com/fil-forge/smelt/pull/11)) implements these
as `staging-allowlist-piri`, `staging-register-piri` and `staging-register-ingot`,
and its runbook is the best statement of the ordering and the failure modes.

**Two proofs, one in each direction.**

The provision Lambda deliberately issues three of the five proofs that smelt
issues. The seed phase could not issue the other two even if it wanted to,
because both involve a key that does not exist when a stage is brought up:

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
carrying the appliance's two DIDs and its public URL.

**There is no shell to run the admin CLIs in.**

smelt reaches sprue and hilt with `docker compose exec`. Here both run as
Fargate tasks in private subnets and `enable_execute_command` is not set on any
service, so `aws ecs execute-command` does not work either. Three ways out:

- turn ECS Exec on and accept a documented human path into a task
- add a Lambda alongside `provision` that performs the writes and issues the hilt proof, reusing its
  SSM access to read hilt's identity;
- or expose the admin operations over the ALB behind authentication, which is the largest change and
  the only one that also serves a self-service future.

The delegator's allow list is the exception and can be written today. Its table
takes a single `did` string as the hash key, so an operator with credentials for
the account writes the item directly without going near a task, once the item
shape the delegator reads has been confirmed against its store package.

**Where this belongs is the open question.**

The appliance knows its own DIDs and its operator runs its bootstrap, which argues for the appliance
pulling. Every write lands in central's tables and databases, and central holds the key that signs
the proof going back, which argues for the authority staying here. The likely answer is both halves:
the appliance presents its DIDs and URL, and tooling in this repository performs the three writes
and returns the proof. Deciding that before the first appliance arrives is cheaper than discovering
it during one.

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

### Publish the provision image from CI

Infrastructure changes reach dev on merge, but the image the Lambda runs does not.
`make publish` is still run by hand from a developer machine with credentials for
the target account, and the digest it writes has to be committed before the deploy
workflow will pick it up.

A workflow on merge to `main` that publishes the image and commits the digest
would close the last manual step. Ordering needs care: the commit carrying the
new digest is what triggers the deploy, so the workflow has to publish before it
writes, and write only what it published.

### Forcing a provision phase to re-run

`aws_lambda_invocation` re-invokes only when its input changes, which is what
`seed_trigger` and `vault_trigger` in `modules/platform` exist for. Rotating an
identity or hilt's OpenBao credential needs one of them bumped.

Neither is reachable today. The stage roots do not expose them, and the workflow
passes no `-var` flags, so the only way to bump one is to edit
`envs/<stage>/platform/main.tf` and merge.

That is arguably the right answer rather than a limitation. A committed, reviewed
diff is what re-running the thing that mints wallets should cost, and it stays
visible afterwards. The alternative — a workflow input anyone with write access
could set — puts that one text field away. A `workflow_dispatch` input would be the
middle ground if the merge ever proves too slow.

### Deploy the remaining services from their own repositories

hilt already does this: its publish workflow dispatches the digest it pushed and
[`bump-deployed-image.yml`](.github/workflows/bump-deployed-image.yml) commits it
to the dev stage. sprue, swarf, delegator, signing_service and plc are still
deployed by editing `image_digests` here.

The receiver accepts all six service names, so wiring one up is a dispatch step
in its publish workflow plus the `fil-forge-bot` credentials in that repository.
It only accepts dispatches made as that app, and the `source_repo` in the
payload has to be the repository the service is published from, so the required
`client_payload` is `service`, `digest` and `source_repo`; `commit`, `pr_url`
and `run_url` are provenance links the commit message uses when present.

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

### There is no restore procedure for RDS

Backups run: seven days of automated snapshots by default, one in dev, and a
final snapshot on delete unless a stage sets `skip_final_snapshot`. Nothing says
how to use them. A restore is also more than the services' data, because
OpenBao's storage lives in the same instance: rolling the database back rolls
back hilt's AppRole and the root of trust regional appliances unseal against.
Write the procedure, and decide as part of it whether OpenBao's storage should
move to an instance of its own.

### Nothing alerts

Logs reach CloudWatch and no alarm reads them. A task that crash-loops, a health
check that starts failing, a wallet that runs out of gas: each is visible to
someone looking, and none of them announces itself. The smallest set worth
having is probably the ECS running count per service and the two wallet
balances. Where the notification goes has to be settled first.

### A stage's running cost is not written down

A stage keeps a NAT gateway, an ALB, an RDS instance and six always-on Fargate
tasks. Nobody has added it up, so there is no figure to weigh against multi-AZ
in prod, a second non-prod stage, or leaving a sandbox stage running over a
weekend.

### Database passwords are static and per-service

The seed phase mints one Postgres password per service and leaves it in SSM,
where it stays until somebody rotates it by hand. RDS IAM authentication would
replace each one with a token minted from the task role and good for fifteen
minutes, so there would be no standing database credential to store, distribute
or leak. It is not a Terraform-only change: the roles need `rds_iam` granted,
the services need to assemble a DSN at startup rather than read a finished one
from SSM, and each driver needs checking for whether it can refresh a token
under a connection pool that outlives it.

### Postgres TLS rides on an engine default

Connections are encrypted because RDS Postgres 16 ships `rds.force_ssl=1` and
the instance uses the default parameter group, which pins nothing. A parameter
group owned here, saying so explicitly, would survive that default changing
under a future engine upgrade. Note what it would not buy: the services connect
with `sslmode=require`, and plc with `no-verify`, which encrypts without
checking who is on the other end. Certificate verification means shipping the
RDS bundle and moving to `verify-full`, which is work in each service rather
than here.

### The database shares subnets with the services it serves

RDS sits in the same private subnets as every task and the provision Lambda.
The separation is entirely the security group's: 5432 admits the service group
and the Lambda group, and nothing else. That is a real control but a single one,
where dedicated subnets with no route out would make the boundary structural.
Moving a live instance is not possible — a new subnet group replaces it, and
this instance is OpenBao's storage — so this is either a decision taken when the
next stage is built from scratch, or it is the paragraph that says the existing
arrangement was chosen rather than overlooked.

## Related

- [smelt](https://github.com/fil-forge/smelt) — the single-VM Docker Compose
  deployment this replaces, and the source of the key generation code.
- [smelt#11](https://github.com/fil-forge/smelt/pull/11) — its appliance
  registration scripts, which are the closest thing to a specification for the
  onboarding tooling this repository still lacks.
- [fil-one/RFC#21](https://github.com/fil-one/RFC/pull/21) — regional security
  and key management, which makes this OpenBao the root of trust for
  appliances.
