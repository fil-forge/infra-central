# The two Forge dashboards, and nothing else in the Grafana stack.
#
# The filecoinfoundation stack is shared. FilOne ships metrics into it from its
# own infrastructure, and the staging appliance's host ships Lotus, Curio and
# Guppy telemetry through the same writer. So this root owns one folder and the
# dashboards inside it, and the credential it runs as cannot reach past that
# folder. What may be declared here:
#
#   grafana_folder, grafana_dashboard, grafana_folder_permission, and later
#   grafana_rule_group. The folders and their permissions are in folders.tf,
#   which is where the three ownership models are set out.
#
# What may not, because each one reaches outside the slice:
#
#   grafana_notification_policy  the whole routing tree as a single resource
#   grafana_data_source          grafanacloud-prom and -logs belong to the stack
#   grafana_organization         not supported on Grafana Cloud at all
#   grafana_team, grafana_user   shared with FilOne
#   grafana_cloud_*              the Cloud org, not this stack
#
# Not in check-and-deploy.yml's plan or apply matrix, for the same reason the
# state key carries no stage: there is no stage whose deploy this belongs to. An
# operator applies it:
#
#   export TF_VAR_grafana_auth="$(op read 'op://Fil One/Forge Central/GRAFANA/GRAFANA_TERRAFORM_TOKEN')"
#   tofu -chdir=terraform/envs/grafana init
#   tofu -chdir=terraform/envs/grafana apply
#
# That token is forge-terraform's, and it is the only one this root ever runs
# as. It holds folder Admin on the three Forge folders and no org role, which is
# enough to manage everything declared here and not enough to create a folder.
# So the folders and their permissions are made once, by hand, by a person with
# org Admin, and this root adopts them through the import blocks at the end of
# this file. Nothing hands an org-admin credential to OpenTofu, at bootstrap or
# after: a wrong plan cannot reach past the three folders even on its first run.
#
# Creating a folder with a chosen uid needs the API; the UI generates one.
#
#   curl -sS -X POST https://filecoinfoundation.grafana.net/api/folders \
#     -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
#     -d '{"uid":"forge","title":"Forge"}'
#
# The uids must match folders.tf exactly: forge, forge-alerts, forge-previews.
# Then grant, on each folder's Permissions tab: forge-terraform Admin on all
# three, forge-sync View on forge, forge-previews Admin on forge-previews. The
# first apply reconciles those grants with what folders.tf declares, so they only
# have to be close enough to let it in.
#
# Same shape as the regional bootstrap root's three Grafana values, and the same
# section of the same 1Password item. 1Password is where an operator's
# credentials live because no workflow can reach it: the only secrets CI consumes
# are FORGE_BOT_PRIVATE_KEY and SLACK_BOT_TOKEN, both repository secrets. This
# root is applied from a laptop, so a laptop credential is what it wants. The
# tokens the preview and sync workflows use are the other way round, and are
# repository secrets that no human types.
#
# The token is not minted here. grafana_service_account_token writes its value
# into state, which is the reason the telemetry Firehoses sit in a bootstrap root
# rather than a stage root; see docs/decisions/2026-09-grafana-telemetry.md. Both
# the service account and its token are made by hand and the token is kept in the
# Forge Central item in the Fil One 1Password vault.

variable "grafana_auth" {
  description = "Service account token for the filecoinfoundation stack. Its basic role is None, so it has no org-level permission at all; its access is Admin on the three Forge folders and nothing anywhere else. Folder Admin rather than Edit because this root declares grafana_folder_permission, and writing a folder's permissions needs that level on the folder. Passed as TF_VAR_grafana_auth, read from the Forge Central item in the Fil One 1Password vault."
  type        = string
  sensitive   = true
}

variable "terraform_service_account_id" {
  description = "Numeric id of the forge-terraform service account, read off Administration -> Users and access -> Service accounts, from the account page, which states it as \"Numeric ID\". Not the uid in the address bar, which is a different identifier this field does not accept. Not a secret. The account is made by hand rather than declared here: managing it would need serviceaccounts:read on every refresh, which the folder-scoped token this root runs as deliberately does not have."
  type        = string
}

provider "grafana" {
  url  = "https://filecoinfoundation.grafana.net/"
  auth = var.grafana_auth
}

# config_json is the whole Kubernetes-style document, apiVersion and kind and
# metadata and spec together, which is what the provider documents for Grafana
# v13 and later. The stack reports 13.3.x. Do not reduce these files to their
# spec: that is the v12 shape.
#
# metadata.name is the uid and is load-bearing in content as well as identity —
# the drill-down data links inside both files hardcode /d/forge-central and
# /d/forge-regions. Changing either breaks the links.
#
# overwrite is left unset on purpose. An apply against a dashboard someone has
# saved in the UI should fail on the version conflict rather than silently
# discard their work, which makes it a crude drift signal on top of the check in
# `make check`.
resource "grafana_dashboard" "central" {
  folder      = grafana_folder.dashboards.uid
  config_json = file("${path.module}/dashboards/forge-central.json")
}

resource "grafana_dashboard" "regions" {
  folder      = grafana_folder.dashboards.uid
  config_json = file("${path.module}/dashboards/forge-regions.json")
}

# Both dashboards already exist in the stack, so the first apply must adopt them
# rather than create them. Creating instead leaves a duplicate under a fresh uid
# while every saved link keeps pointing at the original.
#
# Declared as import blocks rather than run as `tofu import` commands, because a
# command writes shared state the moment someone types it, and these have to be
# runnable before this branch merges. An import block is part of the config: a
# plan shows what it would adopt and writes nothing, it is reviewable in the
# diff, and nobody has to remember two invocations in the right order.
#
# Delete both once the adopting apply has run. They are no-ops after that.
#
# The same applies to anything else the stack already holds. The six blocks
# below are for the bootstrap where a person creates the folders and their
# permissions by hand, so that no run of this root ever needs a credential wider
# than folder Admin -- see the header. Uncomment them once those folders exist;
# until then a plan would fail on a resource it cannot find, which is the right
# order to be forced into.
#
# A folder's import id is its uid, and a folder permission's is the uid of the
# folder it belongs to.
#
#   import {
#     to = grafana_folder.dashboards
#     id = "forge"
#   }
#
#   import {
#     to = grafana_folder.alerts
#     id = "forge-alerts"
#   }
#
#   import {
#     to = grafana_folder.previews
#     id = "forge-previews"
#   }
#
#   import {
#     to = grafana_folder_permission.dashboards
#     id = "forge"
#   }
#
#   import {
#     to = grafana_folder_permission.alerts
#     id = "forge-alerts"
#   }
#
#   import {
#     to = grafana_folder_permission.previews
#     id = "forge-previews"
#   }
import {
  to = grafana_dashboard.central
  id = "forge-central"
}

import {
  to = grafana_dashboard.regions
  id = "forge-regions"
}
