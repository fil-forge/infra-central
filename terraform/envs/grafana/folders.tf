# Three folders, because the three kinds of thing in this root want three
# different answers to "who may change this".
#
#   Forge            Dashboards. The team edits them in the UI; a sync workflow
#                    raises the pull request that brings the change back here.
#                    A dashboard is a view, so a wrong one costs attention and
#                    nothing else, and the gate is worth having after the change
#                    lands rather than in front of it.
#
#   Forge alerts     Alert rules. Git only. A wrong rule pages someone at three
#                    in the morning, or quietly stops paging when it should, so
#                    this one is reviewed before it is real.
#
#   Forge previews   A pull request's dashboards, deployed under their own uids
#                    so a reviewer can look at the thing rather than at a JSON
#                    diff. Disposable: the workflow creates and deletes them, and
#                    this root owns the folder and its permissions but nothing
#                    inside it. That is the only mixed-ownership boundary here,
#                    and it holds because nothing durable lives on the far side.
#
#                    A preview lives exactly as long as its pull request. Every
#                    push redeploys it at the new head, a force-push included,
#                    and closing or merging deletes it. Nothing else expires one,
#                    so there is no sweeper to write and no preview outliving
#                    what it previews.
#
# Grafana org admins bypass folder permissions, so all of this is a guardrail
# rather than a lock.

variable "previews_service_account_id" {
  description = "Numeric id of the forge-previews service account, which holds Admin on the previews folder and nothing else. The preview workflow runs on pull_request, so its credential is reachable by any action a pull request brings with it; scoped this way the worst case is a trashed preview. Not a secret."
  type        = string
}

resource "grafana_folder" "dashboards" {
  uid   = "forge"
  title = "Forge"
}

resource "grafana_folder_permission" "dashboards" {
  folder_uid = grafana_folder.dashboards.uid

  permissions {
    user_id    = var.dashboards_service_account_id
    permission = "Admin"
  }

  # Edit, not View: editing these in the UI is the supported path, and the sync
  # workflow is what makes it safe rather than a permission is.
  permissions {
    role       = "Editor"
    permission = "Edit"
  }

  permissions {
    role       = "Viewer"
    permission = "View"
  }
}

resource "grafana_folder" "alerts" {
  uid   = "forge-alerts"
  title = "Forge alerts (managed in git)"
}

# View for everyone. Grafana marks file-provisioned and Git Sync resources
# read-only and refuses to save over them; a rule written through the HTTP API,
# which is what this provider uses, is an ordinary rule. The permission is the
# only thing stopping a UI edit, so the title says where the truth is.
resource "grafana_folder_permission" "alerts" {
  folder_uid = grafana_folder.alerts.uid

  permissions {
    user_id    = var.dashboards_service_account_id
    permission = "Admin"
  }

  permissions {
    role       = "Editor"
    permission = "View"
  }

  permissions {
    role       = "Viewer"
    permission = "View"
  }
}

resource "grafana_folder" "previews" {
  uid   = "forge-previews"
  title = "Forge previews (disposable)"
}

# Read-only for people, on top of the spec.editable = false that
# scripts/preview-dashboard.sh sets on every preview it writes. Two mechanisms
# because they fail differently: the permission stops a save, the flag stops the
# UI offering one.
resource "grafana_folder_permission" "previews" {
  folder_uid = grafana_folder.previews.uid

  # The account Terraform runs as needs Admin here too, even though it never
  # writes a preview. This resource manages the folder's entire permission set,
  # so it would otherwise remove the implicit grant the account got by creating
  # the folder, and lock Terraform out of a resource it declares.
  permissions {
    user_id    = var.dashboards_service_account_id
    permission = "Admin"
  }

  permissions {
    user_id    = var.previews_service_account_id
    permission = "Admin"
  }

  permissions {
    role       = "Editor"
    permission = "View"
  }

  permissions {
    role       = "Viewer"
    permission = "View"
  }
}
