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

## Development

```bash
make check   # gofmt, go vet, go test, terraform fmt
make test
```

Both run offline against no deployed stage, which is why `make smoke` is
separate: it needs a stage to be up. See [Smoke-testing a
stage](#smoke-testing-a-stage).

## Related

- [smelt](https://github.com/fil-forge/smelt) — the single-VM Docker Compose
  deployment this replaces, and the source of the key generation code.
- [smelt#11](https://github.com/fil-forge/smelt/pull/11) — its appliance
  registration scripts, which are the closest thing to a specification for the
  onboarding tooling this repository still lacks.
- [fil-one/RFC#21](https://github.com/fil-one/RFC/pull/21) — regional security
  and key management, which makes this OpenBao the root of trust for
  appliances.
