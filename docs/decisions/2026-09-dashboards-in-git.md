# The Forge dashboards are Terraform, in a root of their own

The two Grafana dashboards on-call reads during a SpiderOak perf run or an SP
deployment are committed here and applied with the Grafana Terraform provider:

- `Forge Central`, uid `forge-central`, the central services.
- `Forge Regions`, uid `forge-regions`, the appliances.

They live in `terraform/envs/grafana/`, with the JSON beside the root in
`dashboards/`. Where the metrics behind them come from is in
[../observability.md](../observability.md) here and in
[infra-nodes' observability.md](https://github.com/fil-forge/infra-nodes/blob/main/docs/observability.md).

## One root, no stage, applied by an operator

Both dashboards describe every stage at once, through a `$stage` template
variable that reads `label_values(dimension_ClusterName)`. There is no stage
whose deploy they belong to, so they are not in `check-and-deploy.yml`'s plan or
apply matrix and the state key carries no stage prefix. An operator applies the
root the way they apply the regional bootstrap roots.

The state lives in the nonprod bucket because that is where an operator already
applies from, and because nothing in this root is account-specific. Its key is
`grafana/forge.tfstate`, under a prefix like every other key in that bucket, and
outside every prefix in `github-actions-iam`'s `state_key_prefixes` — which is
one per stage the workflow deploys, and which already holds `bootstrap` out on
the same grounds: "applied by an operator from a laptop, so no CI role needs to
write it". Neither CI role can touch this state. If CI ever applies this root,
adding `grafana` to that list is the whole IAM change.

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
2. **What the token can reach.** A dedicated `forge-dashboards-terraform` service
   account with Admin on the Forge folder and no org role beyond that. A wrong
   plan, or a `tofu destroy` in the wrong directory, cannot touch anyone else's
   dashboards, because the credential cannot see them.
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

## Scope

Dashboards only. Alert rules are the other half of every ticket under
[FIL-1208](https://linear.app/filecoin-foundation/issue/FIL-1208) and belong in
this root when they land — `grafana_rule_group` and `grafana_contact_point` are
per-resource and adopt incrementally. `grafana_notification_policy` is not:
it manages the whole routing tree, so adopting it means Terraform owns every
route in a shared stack, and that is a separate decision.

There is no drift check against the live stack. `make check` verifies the
committed files are in normal form, not that Grafana agrees with them. Leaving
`overwrite` unset on both dashboards is the crude substitute: an apply against a
dashboard someone saved in the UI should fail on the version conflict rather than
discard their work. A real check would fetch both by uid, normalise and diff,
which needs the token in CI.
