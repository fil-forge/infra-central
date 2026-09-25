# The Forge dashboards and alert rules are Terraform, in a root of their own

The two Grafana dashboards on-call reads during a SpiderOak perf run or an SP
deployment are committed here and applied with the Grafana Terraform provider:

- `Forge Central`, uid `forge-central`, the central services.
- `Forge Regions`, uid `forge-regions`, the appliances.

They live in `terraform/envs/grafana/`, with the JSON beside the root in
`dashboards/`. Where the metrics behind them come from is in
[../observability.md](../observability.md) here and in
[infra-nodes' observability.md](https://github.com/fil-forge/infra-nodes/blob/main/docs/observability.md).

## One root, no stage, applied by an operator until CI is turned on

Both dashboards describe every stage at once, through a `$stage` template
variable that reads `label_values(dimension_ClusterName)`. There is no stage
whose deploy they belong to, so they are not in `check-and-deploy.yml`'s plan or
apply matrix and the state key carries no stage prefix. An operator applies the
root the way they apply the regional bootstrap roots.

`check-and-deploy.yml` carries an `apply-grafana` job for the day that stops
being enough. It is gated on a `GRAFANA_APPLY_ENABLED` repository variable and
does nothing until someone sets it, because it has two prerequisites outside
this repository's normal flow: a `GRAFANA_TERRAFORM_TOKEN` secret, and
`grafana` added to the account bootstrap root's `state_key_prefixes` so the
apply role can reach this root's state. Without the second, every push to main
would fail at `tofu init`.

It runs on push only, which is what keeps the token out of pull requests: a job
gated that way is never instantiated by one, so a bumped action in a Dependabot
branch never sees the secret. There is no plan job for the grafana root for the
same reason — a plan runs on `pull_request`, which is exactly where the token
must not be — and a dashboard change is reviewed from its preview rather than
from a plan.

The state lives in the nonprod bucket because that is where an operator already
applies from, and because nothing in this root is account-specific. Its key is
`grafana/forge.tfstate`, under a prefix like every other key in that bucket.
`grafana` sits in `github-actions-iam`'s `state_key_prefixes` alongside the one
entry per stage the workflow deploys, so both CI roles can reach this state: the
apply role to write it, the plan role to read it. That grant lands when someone
applies `terraform/envs/bootstrap/nonprod/account` by hand — the root that
creates the roles — and not when the change to it merges.

`bootstrap` is still held out of the same list, on the grounds the variable's
description gives: "applied by an operator from a laptop, so no CI role needs to
write it". That reasoning stopped applying to the grafana root the moment CI was
going to apply it.

## The whole Kubernetes-style document goes in config_json

The stack runs Grafana 13.3.x and both dashboards are schema v2 —
`apiVersion: dashboard.grafana.app/v2`, with `kind`, `metadata` and `spec`. The
provider documents `grafana_dashboard.config_json` as taking the full document
for Grafana v13 and later, and only the `spec` field for v12. Reducing these
files to their `spec` would be the v12 shape and is wrong here.

`metadata.name` is the uid, and it is load-bearing in content as well as in
identity: the drill-down data link on each overview table hardcodes
`/d/forge-central` and `/d/forge-regions`. Renaming either breaks the links
inside the other panels.

Both dashboards already exist in the stack, so the first apply has to import
them. Creating instead leaves a duplicate under a fresh uid while every link
anyone has saved still points at the original.

## Three folders, three answers to who may change this

The filecoinfoundation stack is shared. FilOne ships metrics into it from its own
infrastructure, and the staging appliance's host ships Lotus, Curio and Guppy
telemetry through the same writer.

The first cordon is between Forge and everyone else in the stack. The second is
inside Forge, and it is not one line: a dashboard is a view, so a wrong one costs
attention and the review is worth having after the change lands, while a wrong
alert rule pages someone at three in the morning or quietly stops paging, so that
review belongs in front of it. `folders.tf` holds the three folders that
follow — `Forge` where the team edits dashboards in the UI and a sync workflow
raises the pull request that brings the change back, `Forge alerts` which is git
only, and `Forge previews`, where a pull request's dashboards are deployed under
their own uids so a reviewer can look at the thing rather than at a JSON diff.

The outer cordon is four things, in order of how much they actually protect:

1. **What the root may declare.** Folders, the dashboards and rules in them, and
   the folders' permissions. The header of `main.tf` carries the list, and the list
   of what is excluded and why: `grafana_notification_policy` is the entire
   routing tree as one resource, `grafana_data_source` would claim
   `grafanacloud-prom` and `-logs`, which belong to the stack, and teams, users
   and `grafana_cloud_*` are shared with FilOne or describe the Cloud org rather
   than this stack.
2. **What the token can reach.** A dedicated `forge-terraform` service account,
   basic role `None`, holding the folder permission `Admin` on the three Forge
   folders and nothing anywhere else. `Admin` there is the folder level, not the
   org role: the account has no org-level permission at all. It needs the folder
   level rather than `Edit` because this root declares
   `grafana_folder_permission`, and writing a folder's permissions needs `Admin`
   on that folder. A wrong plan, or a `tofu destroy` in the wrong directory,
   cannot touch anyone else's dashboards, because the credential cannot see them.
3. **What people can do.** `grafana_folder_permission` gives the Editor and
   Viewer basic roles `View` on the folder. It manages the folder's entire
   permission set, so a grant added by hand is removed on the next apply, which
   is why it is the right resource here rather than
   `grafana_folder_permission_item`. It is a guardrail and not a lock: Grafana
   org admins bypass folder permissions.
4. **Saying so.** `Forge alerts` and `Forge previews` carry what they are in
   their titles, because nothing enforces it. Grafana marks file-provisioned and
   Git Sync resources as provisioned and refuses to save over them; anything
   written through the HTTP API, which is what this provider uses, is ordinary
   and anyone with Edit can overwrite it. The dashboards folder says nothing of
   the sort, because there editing is the supported path.

If the cordon needs to be enforced rather than agreed, that is the argument for
Grafana's Git Sync over this provider: it scopes a sync to a folder and marks
what it syncs read-only, which is item 4 done server-side. It was not available
to check when this landed.

## The token is not minted here

`grafana_service_account_token` writes its value into state. That is the same
reason the telemetry Firehoses sit in a bootstrap root rather than a stage root
([2026-09-grafana-telemetry.md](2026-09-grafana-telemetry.md)), and it applies
again. The service account and its token are both made by hand and the token is
kept in the Forge Central item in the Fil One 1Password vault, passed as
`TF_VAR_grafana_auth`.

The service account is also not declared here, which is a second-order
consequence: Terraform refreshes every resource it manages, reading a service
account needs `serviceaccounts:read`, and the folder-scoped token deliberately
has none. Declaring it would force every apply to run as an org admin and item 2
above would buy nothing. Its numeric id is committed in `terraform.tfvars`
instead, which is not a secret.

The first apply is the exception: creating the folder and setting its permissions
needs an org-admin token, because the narrow token's permission does not exist
until that apply has run. Use an admin token once, then switch to the narrow one.

## Diffs have to mean something

A UI export carries fields that describe the server rather than the dashboard —
`resourceVersion`, `generation`, `creationTimestamp` and `updatedBy` under
`metadata` — plus the cached option list behind every template variable and
whichever variable values the last person to save happened to have selected.
Left in, every re-export rewrites lines that mean nothing.

`scripts/normalise-dashboard.sh` strips those and takes the variable selections
from the file already in git. `make check` runs its `--check` mode over both
committed dashboards, so a raw export cannot land by accident; it needs no
credentials and no network, which is what lets it sit in `check`.

Two sources of churn are left alone on purpose. Every panel carries a
`vizConfig.version` naming the Grafana build it was last edited under, so a Cloud
upgrade plus one save rewrites all of them; dropping the field would be a guess
about whether Grafana still accepts the document without it. And a variable added
in the UI has no counterpart in the committed file, so its selection passes
through as exported.

## Alert rules carry a routing label; the routing tree stays in the UI

`grafana_rule_group` sits in the same folder, in `alerts.tf`. Routing does not.

Every rule carries `team = "forge"`, and a route in the notification policy tree
turns that label into a channel. The tree is not managed here, for the same
reason as everything else in the excluded list: `grafana_notification_policy` is
the whole tree as a single resource, so owning it would mean owning FilOne's
routes. `grafana_contact_point` is excluded for a second reason as well — a Slack
integration keeps its token or webhook as an ordinary attribute, which would put
a secret in this state exactly as a Firehose's access key would.

`rule.notification_settings` would attach a contact point per rule and bypass the
policy, but it needs the `alertingSimplifiedRouting` feature flag and it hides
routing from whoever maintains the tree. One route matching `team = "forge"`,
added by hand once, covers every rule this root will ever add.

Grafana alert rules have no template variables, so the stage and region
templating that `$stage` and `$region` do in the dashboards is done in Terraform
instead. `var.alert_stages` builds every stage-dependent matcher — the
appliance label's prefix, Central's `fc-<stage>` load balancer and target group
names — and grouping by `appliance, region, node` or by `service` gives one alert
instance per node or service without naming any of them. A new region needs no
edit.

## Scope

Four rules, in two groups. Three replace rules built by hand in the UI while
there was no service account to apply Terraform with — no healthy hosts behind a
target group, Central's 5xx count, and an appliance that has stopped reporting —
and the fourth is
[FIL-1209](https://linear.app/filecoin-foundation/issue/FIL-1209)'s disk-space
rule. The hand-built ones were exported and translated, so the expression stages
here follow shapes Grafana itself wrote rather than the provider's
documentation.

Of the seven alerts under
[FIL-1145](https://linear.app/filecoin-foundation/issue/FIL-1145), FIL-1209 is
still the only one that states a threshold. The others say "too high", or take
theirs from an SLO that has not been written
([FIL-1242](https://linear.app/filecoin-foundation/issue/FIL-1242)), or ask for a
decision the team has not taken. The head of `alerts.tf` lists each one and what
it is waiting on. A guessed threshold pages someone against a number nobody
agreed, which is worse than no rule at all.

Every one of those tickets is production-only, and production does not exist yet
([FIL-1147](https://linear.app/filecoin-foundation/issue/FIL-1147),
[FIL-808](https://linear.app/filecoin-foundation/issue/FIL-808)).
[FIL-1207](https://linear.app/filecoin-foundation/issue/FIL-1207) anticipates
that: rules are authored now and templated by stage so they apply when
production is stood up. `var.alert_stages` defaults to `["prod"]` for that day;
`terraform.tfvars` holds `["staging"]` until then, because staging is what the
rules these replace were watching and an alert nobody can trigger is not an
alert.

There is no drift check against the live stack. `make check` verifies the
committed files are in normal form, not that Grafana agrees with them. Leaving
`overwrite` unset on both dashboards is the crude substitute: an apply against a
dashboard someone saved in the UI should fail on the version conflict rather than
discard their work. A real check would fetch both by uid, normalise and diff,
which needs the token in CI.
