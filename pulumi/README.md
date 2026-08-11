# Pulumi

Three projects, each a Go program, replacing the six HCP Terraform workspaces.

```
pulumi/
  bootstrap/          ECR repositories, one stack per account and region
  platform/           a stage's VPC, RDS, S3, DynamoDB, ALB, OpenBao, Lambda
  apps/               a stage's six ECS services
  internal/           the shared components, one package per Terraform module
```

## Workspaces became stacks

A Terraform workspace was a directory plus a `cloud` block naming it. A Pulumi
stack is a name plus a config file, so the two stages of a project share one
program and differ only in configuration. That is the whole reason the tree got
smaller: `envs/dev/platform` and `envs/prod/platform` were two copies of the same
wiring, and now there is one.

| Terraform workspace                          | Pulumi stack                             |
| -------------------------------------------- | ---------------------------------------- |
| `forge-central-bootstrap-nonprod-us-east-2`  | `forge-central-bootstrap/nonprod-us-east-2` |
| `forge-central-bootstrap-prod-us-east-2`     | `forge-central-bootstrap/prod-us-east-2` |
| `forge-central-dev-platform`                 | `forge-central-platform/dev`             |
| `forge-central-dev-apps`                     | `forge-central-apps/dev`                 |
| `forge-central-prod-platform`                | `forge-central-platform/prod`            |
| `forge-central-prod-apps`                    | `forge-central-apps/prod`                |

**The stack name is the stage.** Nothing else names it. `ctx.Stack()` is what
`var.stage` used to be, which is what keeps a stage's label and the resources it
refers to from coming apart.

## Modules became packages

| Terraform module                       | Go package                            |
| -------------------------------------- | ------------------------------------- |
| `modules/shared/constants`             | `internal/constants`                  |
| `modules/shared/ecs-service`           | `internal/ecsservice`                 |
| `modules/ecr`                          | `internal/ecr`                        |
| `modules/platform`                     | `internal/platform`                   |
| `modules/platform/{network,kms,…}`     | `internal/platform/{network,kms,…}`   |
| `modules/apps`                         | `internal/apps`                       |

Each package exports `Args` and a `New` that returns a component resource. A
Terraform `variable` with a default is a field left at its zero value; a
`variable` with a `validation` block is a check in `New` that fails before
anything is created.

Three helpers have no Terraform counterpart because they replace things the
language gave for free:

- `internal/cidr` — Terraform's `cidrsubnet`.
- `internal/iamdoc` — the `aws_iam_policy_document` data source.
- `internal/stack` — the provider with its account guard, and typed reads of
  another stack's outputs.

## What each program does differently

**`tfe_outputs` became a stack reference.** The apps program reads the platform
stack of the same name. Terraform had to reach for `nonsensitive_values` there,
because `tfe_outputs` marked the whole output map sensitive and the taint spread
to everything derived from it; Pulumi keeps each output's own secretness, so there
is nothing to strip.

**The run trigger became a data dependency.** HCP ordered the two workspaces with
a trigger on the platform workspace. The stack reference does that itself: apps
cannot run ahead of the outputs it reads.

**`allowed_account_ids` comes from code.** A stack names the account it belongs to
— `forge-central:account: nonprod` — and `internal/stack` maps that to the number
in `internal/constants`. The guard is still what fails the run when credentials
point at the wrong account, but the account number is not a value anyone can
mistype into a config file.

**`image.auto.tfvars` became a config value.** `make publish` writes
`forge-central:provisionImageDigest` into `platform/Pulumi.dev.yaml`, which is
committed for the same reason the tfvars file was: what is not committed is not
what gets deployed.

**Lifecycle rules.** `create_before_destroy` is gone from the ACM certificate and
the target group because Pulumi already creates a replacement before deleting the
original. The RDS instance's `replace_triggered_by` became
`ReplaceOnChanges(["dbSubnetGroupName"])`, which is the property that actually
carries the change Terraform was working around.

## Two things to know before editing

**Sort anything that becomes JSON.** Terraform iterated maps in sorted order. Go
does not, so an unsorted environment block or wrapper prelude would rewrite the
task definition on every run and restart every task. `internal/ecsservice` sorts
deliberately, and `wrapper_test.go` holds that line.

**Nullness is decided while the graph is built.** A service with no public
hostname passes `Hostname: nil`, and that is what suppresses its target group,
listener rule and DNS record — exactly when Terraform's `count = var.hostname ==
null ? 0 : 1` decided the same thing. A value that arrives as an output cannot be
used for that decision, which is why the stage name is the stack name rather than
something read from another stack.

## Running it

The stacks are previewed and deployed with the ordinary commands, from the
project directory:

```
pulumi -C pulumi/platform preview --stack dev
pulumi -C pulumi/platform up --stack dev
pulumi -C pulumi/apps up --stack dev
```

`platform` before `apps`, first time through, because apps reads its outputs.

The tests need no credentials, backend or network: they build every component
against a mocked resource monitor in `internal/mockaws`, which is what catches an
apply whose types do not line up.

```
go test ./pulumi/...
```
