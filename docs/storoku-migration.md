# Migrating to Storoku

An assessment of moving this repository's Terraform to
[Storoku](https://github.com/storacha/storoku), against `storoku` **v0.6.2**
(`c9a45f8`, the current release at the time of writing).

**Verdict: not possible today without changing the deployment.** Storoku models
one public HTTP service per repository. This repository deploys seven ECS
services that share one ALB, one ECS cluster, one RDS instance and one Cloud Map
namespace, plus an OpenBao and a provisioning Lambda that Storoku has no concept
of. The parts Storoku does cover it would rebuild under different names, in a
different state backend, with secrets in a different store — so nothing here can
be handed over in place.

What follows is the mapping, the blockers with references, and the upstream work
that would close them. Nothing in this repository is changed by this document.

## Contents

- [What Storoku is](#what-storoku-is)
- [Why in-place adoption is impossible](#why-in-place-adoption-is-impossible)
- [Resource mapping](#resource-mapping)
- [Blockers](#blockers)
- [What would make this possible](#what-would-make-this-possible)
- [Options](#options)

## What Storoku is

A code generator plus a library of remote Terraform modules. `storoku new
<app>` writes `.storoku.json`, a `deploy/` directory, a `Makefile` and GitHub
Actions workflows; later `storoku <subcommand>` calls mutate the JSON and
regenerate every file that does not open with `# storoku:ignore`.

The generated `deploy/app/main.tf` instantiates `module "app"` exactly once, and
that module composes the rest: `vpc`, `postgres`, `kms`, `secret`, `cert`,
`ecs-infra`, `deployment`, `s3`, `dynamodb`, `sqs`, `sns`, `elasticaches`.

The shape it produces, per deployment:

| Storoku builds                    | Detail                                                                  |
| --------------------------------- | ----------------------------------------------------------------------- |
| One ECS cluster                   | `ecs-infra/cluster.tf`                                                  |
| One internet-facing ALB           | `ecs-infra/alb.tf`, one HTTPS listener, default action, no host rules    |
| One ACM certificate               | `cert/main.tf`, single name, not a wildcard                              |
| One task definition, one container | `deployment/ecs_task.tf`, container hard-named `first`                  |
| One ECS service, blue/green       | `deployment/ecs_service.tf` + `codedeploy.tf`, autoscaled `min`–`max`    |
| Secrets in Secrets Manager        | `secret/main.tf`, `/${app}/${environment}/Secret/${NAME}/value`          |
| Optional Postgres, buckets, tables, queues, topics, caches | one set per app                                 |
| State in S3                       | `storacha-terraform-state`, `us-west-2`, via OpenTofu                    |

`environment` is `terraform.workspace`. Only `prod` and `staging` get dedicated
VPC/RDS/KMS; every other workspace name reads the shared *dev* VPC, database and
KMS key out of a second state file (`app/locals.tf`, `app/remote.tf`).

## Why in-place adoption is impossible

Even setting the architectural gaps aside, Storoku cannot take ownership of the
resources this repository already manages. Three reasons, each sufficient alone.

**Naming is fixed and different.** Storoku derives every name from
`${var.environment}-${var.app}`: `dev-sprue-rds-instance`, target groups
`dev-sprue-blue` and `dev-sprue-green`, task family `dev-sprue`, log group per
its own `ecs-infra/cloudwatch.tf`. This repository uses `fc-<stage>-<service>`
and `/forge-central/<stage>/<service>`. The abbreviation is load-bearing — a
target group name is capped at 32 characters and `fc-dev-signing-service` was
chosen to fit. Adopting the existing resources would mean importing them under
names Storoku will not generate, and every subsequent `storoku regen` would plan
them away.

**The secret store is different.** Storoku's `secret` module creates
`aws_secretsmanager_secret`. This repository's secrets are SSM parameters, and
deliberately so: they are minted by the provision Lambda, Terraform has no
record of them, and that is exactly what stops `terraform destroy` burning a
funded wallet. There is no import path from one to the other, and moving them
would discard that property.

**State lives somewhere this project cannot use.** Both generated backends
hard-code `bucket = "storacha-terraform-state"` in `us-west-2`
(`template/deploy/app/main.tf`, `template/deploy/shared/main.tf`). This project's
roots use HCP Terraform `cloud` blocks in the `Filecoin_Foundation` organization,
with OIDC role assumption per run and run triggers ordering `platform` before
`apps`. Storoku's `deploy/Makefile` also pins the ECR registry to `us-west-2`
and defaults `TF_VAR_allowed_account_id` to Storacha's account.

## Resource mapping

This repository manages 35 distinct resource types across its workspaces. Where
each lands:

| This repository                                                    | Storoku                                                                                    |
| ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------ |
| VPC, subnets, IGW, NAT, route tables (`modules/platform/network`)   | ✅ `vpc` module — and adds DB/elasticache subnets and seven VPC endpoints this stage lacks |
| RDS Postgres + subnet group (`modules/platform/database`)            | ✅ `postgres` module, one instance per app                                                  |
| 3 S3 buckets (`modules/platform/storage`)                           | ✅ `buckets` in `.storoku.json`                                                             |
| 2 DynamoDB tables (`modules/platform/storage`)                      | ✅ `tables`, with hash/range keys and secondary indexes                                     |
| ECR repository (`modules/ecr`, bootstrap)                           | ✅ `shared/ecr.tf`, as `${app}-ecr`                                                         |
| ECS cluster (`modules/platform`)                                    | ⚠️ one per app, not one per stage                                                           |
| ALB + HTTPS listener + HTTP redirect (`modules/platform/ingress`)    | ⚠️ one per app; no host-based listener rules                                                |
| Wildcard ACM cert `*.<suffix>` + validation                         | ⚠️ `cert` issues one name per deployment                                                    |
| Route53 A records per service                                       | ⚠️ created, but from zones Storoku's `shared` workspace owns                                |
| KMS key + alias for OpenBao auto-unseal (`modules/platform/kms`)     | ⚠️ `kms` exists, but scoped to encrypting secrets/RDS                                       |
| 6 ECS services sharing the cluster (`modules/apps`)                 | ❌ one service per deployment                                                                |
| OpenBao service, KMS seal, Postgres storage (`modules/platform/openbao`) | ❌ no concept                                                                          |
| Provision Lambda + 2 `aws_lambda_invocation` phases (`modules/platform/provision`) | ❌ no general Lambda support                                               |
| SSM parameters under `/forge-central/<stage>/<service>/*`            | ❌ Secrets Manager only                                                                     |
| Cloud Map namespace + per-service discovery                         | ❌ absent from Storoku entirely                                                              |
| Entrypoint wrapper writing file-borne secrets (`modules/shared/ecs-service`) | ❌ no `entryPoint`/`command` override                                               |
| Per-service health paths                                            | ❌ hard-coded `/healthcheck`                                                                 |
| HCP workspaces, run triggers, OIDC                                  | ❌ S3 backend + GitHub Actions                                                               |

## Blockers

### One app per deployment

`Config.App` is a single string and `deploy/app/main.tf` calls `module "app"`
once (`cmd/storoku/main.go:281`, `template/deploy/app/main.tf:42`). Six services
means six deployments.

They *could* share infrastructure: `module "app"` takes both `app` and
`appState`, and `appState` selects which `shared.tfstate` to read
(`app/remote.tf:7`), so several apps pointed at one `appState` would share a VPC,
database, KMS key and DNS zone. The generated template hard-codes `appState =
var.app`, so using it would mean ejecting that file in each of the six.

Two things that sharing does not fix. Each app still builds its own ECS cluster
and its own ALB, because `ecs_infra` sits inside `module "app"` — six ALBs where
this stage has one, which is a cost and a DNS change, not a refactor. And
`local.dedicated_resources` is true only for `prod`/`staging`
(`app/locals.tf:2-7`), so a `prod` deployment gets a dedicated VPC per app and
cannot share at all.

Storoku is also single-config-per-directory rather than strictly per-repository —
it reads `./.storoku.json` and writes relative to the working directory — so six
subdirectories would each generate a deployment. But the generated
`.github/workflows/*` would land in those subdirectories, where GitHub does not
look for them, so the CI half of what Storoku generates would not run.

### Shared ingress

`ecs-infra/alb.tf` creates an `aws_lb` with `internal = false` and a single
listener whose default action forwards to the app's blue target group. There are
no `aws_lb_listener_rule` resources and no host-header conditions anywhere in
Storoku. This repository routes five hostnames through one ALB at fixed listener
priorities — 100 for OpenBao, 110–150 for the services — and the wildcard
certificate exists precisely so one ALB can serve all of them.

### Internal-only services

`plc` has no public hostname by design, matching smelt, and is reached at
`http://plc.<namespace>:3000` through Cloud Map. Storoku gives every app a public
ALB and an `aws_route53_record` unconditionally (`app/route53.tf`), and contains
no service-discovery resources at all. There is no way to express `plc` without
exposing it.

### Secrets: store, and where the values live

Two separate problems.

The store is Secrets Manager, not SSM Parameter Store — covered above.

The bigger one is that Storoku's secret *values* pass through Terraform.
`module "app"` takes `secrets` as a map of values, and the generator emits either
a `random_password` resource or a `var` reference for each
(`template/deploy/app/main.tf:34-65`). The service identity key is a first-class
variable, `TF_VAR_private_key`, and the generated `.env.terraform.tpl` says
`# private_key or your env -- do not commit to repo!`.

That inverts this project's central decision. Keys here are generated inside the
VPC by the provision Lambda, which returns only DIDs, addresses and names; no
private key enters Terraform state, and the plan sees only parameter ARNs that
ECS resolves at task start.

Storoku's `external_secrets` is the closest fit — a `data` lookup for secrets
provisioned out-of-band, with no value in the configuration — but it still reads
Secrets Manager, and it cannot express the per-service IAM scoping that makes a
compromised sprue task unable to read hilt's AppRole `secret_id`.

### File-borne secrets

hilt and swarf accept an identity key only as a file path, and the delegator's
two UCAN proofs are file-only in current code. ECS injects secrets as
environment variables, so `modules/shared/ecs-service/main.tf` wraps the
entrypoint: it writes each secret into a tmpfs under `/tmp/forge`, base64-decoding
the two that are bare DAG-CBOR and would otherwise carry NUL bytes, then execs
the real process.

Storoku's container definition sets no `entryPoint` and no `command`
(`deployment/ecs_task.tf:16-50`). Without an override, three of the six services
cannot start with a stable identity.

### Health checks

`healthcheck` is a bool, and when true the command is
`curl -f http://localhost:${port}/healthcheck` (`deployment/ecs_task.tf:41`);
both ALB target groups also hard-code `path = "/healthcheck"`
(`ecs-infra/alb.tf:21-37`). This stage needs `/health` for sprue, hilt and swarf,
`/healthcheck` for the delegator and signing service, and `/_health` for plc —
and `curl` is not in every image: the delegator and signing service are Alpine
based and are probed with `wget --spider`.

The matcher is also `200,301,302,404`, which treats a 404 as healthy. That would
report all three of the `/health` services as passing while their real health
path went unqueried.

### Deployment strategy and the migration lock

Storoku deploys blue/green through CodeDeploy with autoscaling between
`service_min` and `service_max` — 1–2 for non-prod, 1–10 for prod
(`app/locals.tf:31-46`). Migrations here run in-process via goose for sprue,
hilt, swarf and plc, and concurrent starts race on the goose advisory lock, so
every service runs at `desired_count = 1` with
`deployment_minimum_healthy_percent = 0` until someone sets the relevant
`*_SKIP_MIGRATIONS`. Scaling to two tasks is not a tuning choice here; it needs
the migration change first.

### OpenBao and the provision Lambda

Neither has an analogue. OpenBao is an ECS service with a KMS seal, Postgres
storage in the shared RDS instance, an ALB route at `ssm.<suffix>` and an
initialisation phase that runs after the task is up — and it is the root of trust
regional appliances unseal against. The provision Lambda is a container-image
function in the VPC, invoked by Terraform in two ordered phases, that mints every
identity and wallet and creates the per-service databases.

Storoku has one Lambda of its own, `postgres-provisioner`, which creates an app
database and role. It is not a general mechanism for running project code.

### Chain configuration and image sources

Service images come from `ghcr.io/fil-forge/*` pinned by digest. Storoku builds
and pushes the app's image to its own `${app}-ecr` and tags it
`${workspace}-${sha}` through `deploy/Makefile`, which assumes the repository
being deployed *is* the application. This repository deploys six images built
elsewhere.

Non-secret configuration would move to `deploy/.env.production.local.tpl`, an ESH
template. Workable, but it replaces the typed `chain` object that both workspaces
read today with shell-templated strings.

## What would make this possible

In rough dependency order, as upstream changes to `storacha/storoku`:

1. **Multi-service deployments.** `.storoku.json` grows a list of services, each
   with its own image, port, environment and secrets, sharing one cluster, ALB,
   database and namespace. This is the change everything else waits on.
2. **Shared ingress.** Let `ecs-infra` accept an existing listener ARN and a
   priority, and add host-header rules; support a wildcard certificate covering
   the deployment's suffix.
3. **Secret backends.** SSM Parameter Store alongside Secrets Manager, secrets
   referenced by path without their values entering the configuration, and
   per-service IAM scoping of the execution role.
4. **Internal services.** Make `hostname` optional and add Cloud Map
   registration for services with no public route.
5. **Health checks as data.** A path and a command per service rather than a
   bool, and a matcher that does not accept 404.
6. **Entrypoint override.** `entryPoint`/`command` on the container, or a
   first-class "write these secrets to files" feature.
7. **Deployment strategy.** An option for rolling at `desired_count = 1` with
   `minimum_healthy_percent = 0`, for services that migrate in-process.
8. **Backend choice.** HCP Terraform `cloud` blocks as an alternative to the
   hard-coded S3 backend, or at minimum a configurable bucket, region and
   account.

Items 1–3 are the substantial ones. Without them there is no migration; with
them, most of `modules/platform` and `modules/apps` could go. OpenBao and the
provision Lambda would stay hand-written either way, which is fine — they are the
part of this deployment that is genuinely specific to it.

Worth noting that `app/locals.tf:2` already special-cases
`var.environment == "forge-test"` as production, so some Forge-shaped
requirement has reached Storoku before. Whoever added it is the right person to
talk to about items 1–3.

## Options

| Option                                            | Deployment change                                                             | Verdict                                                                              |
| ------------------------------------------------- | ----------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| Migrate as-is                                     | Impossible                                                                    | Storoku cannot express seven services on shared ingress, or SSM-minted secrets.       |
| Pilot `piri-signing-service`                      | New VPC, ALB, cluster, hostname; secrets copied to Secrets Manager             | The only service that nearly fits: no Postgres, no file-borne secrets, keys inline. Builds infrastructure parallel to the existing stage rather than adopting any of it. |
| Six deployments sharing an `appState`             | Six ALBs, six clusters, Secrets Manager, ejected templates in each             | Largest diff, and OpenBao, the Lambda, the network and Cloud Map still stay in Terraform. Two systems owning one VPC. |
| Upstream items 1–3, then migrate                  | None, if the features land as described                                        | The only path that ends with this stage managed by Storoku and deployed as it is now. |

Recommended: treat items 1–3 as the prerequisite and raise them with the Storoku
maintainers before writing any deployment code here. If a pilot is wanted sooner
to build familiarity, `piri-signing-service` is the service to use, understanding
that it stands up new infrastructure beside the current stage rather than taking
anything over.
