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
| **Two workspaces per stage**                    | `platform` holds the VPC, RDS, OpenBao and ingress; `apps` holds the services. A routine image bump plans in seconds and never touches the database.                                                                            |
| **Images pinned by digest**                     | A git SHA names the last commit, not the code you just built, so it collides with itself against a dirty tree. A manifest digest is content-derived and cannot move underneath a deploy.                                        |
| **S3 and DynamoDB through task roles**          | No static access keys anywhere. This is what replaces MinIO's root user and password.                                                                                                                                           |

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
  envs/                                            one directory per workspace
    bootstrap/<account>/<region>/                  one workspace per registry
    dev/platform/    dev/apps/
    prod/platform/   prod/apps/                    committed, no workspaces yet
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

The delegation itself lives in
[fil-one/infrastructure](https://github.com/fil-one/infrastructure) and is added
once per workspace: an `aws_route53_zone` for the delegated name, plus a
Cloudflare `NS` record carrying that zone's four name servers, named
`forge-sandbox` in the non-prod workspace and `forge` in the prod one.

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
- **Terraform 1.15 or newer**, for the bootstrap workspaces and for reading a
  stage's outputs. Stage applies themselves run on HCP's runners.
- **Docker with buildx**, for `make publish`.
- **Go and make**, for `make check` and `make test`.
- **[Foundry](https://getfoundry.sh)'s `cast`**, only to read chain balances by
  hand. Nothing in the deploy path needs it.

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
line to edit by hand. **Commit that file and merge it.** The stage plans in HCP,
which sees only what is in version control, so a digest left on your machine is
applied nowhere.

Promoting the same image to prod will be a copy of that digest into
`terraform/envs/prod/platform/terraform.tfvars`, done deliberately when the
change is ready rather than as a side effect of a build.

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
make check   # gofmt, go vet, go test, terraform fmt
make test
```

Both run offline against no deployed stage, which is why `make smoke` is
separate: it needs a stage to be up. See [Smoke-testing a
stage](#smoke-testing-a-stage).

## Planned work

Deliberate compromises and open questions. Some need a change outside this
repository; the rest are work that has not been done here yet.

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

## Related

- [smelt](https://github.com/fil-forge/smelt) — the single-VM Docker Compose
  deployment this replaces, and the source of the key generation code.
- [smelt#11](https://github.com/fil-forge/smelt/pull/11) — its appliance
  registration scripts, which are the closest thing to a specification for the
  onboarding tooling this repository still lacks.
- [fil-one/RFC#21](https://github.com/fil-one/RFC/pull/21) — regional security
  and key management, which makes this OpenBao the root of trust for
  appliances.
