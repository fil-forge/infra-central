# One Forge tree, three children, three different answers to "who may change
# this".
#
#   Forge/                 Holds nothing itself. Its permissions are the floor
#                          the whole tree stands on, which is why it is View for
#                          everyone: a subfolder can add to what it inherits and
#                          cannot take any of it away.
#
#     Dashboards           The team edits them in the UI; a sync workflow raises
#                          the pull request that brings the change back here. A
#                          dashboard is a view, so a wrong one costs attention
#                          and nothing else, and the gate is worth having after
#                          the change lands rather than in front of it. This is
#                          the only child that adds Edit.
#
#     Alerts               Alert rules. Git only. A wrong rule pages someone at
#                          three in the morning, or quietly stops paging when it
#                          should, so this one is reviewed before it is real. It
#                          adds nothing, so it is View by inheritance.
#
#     Previews             A pull request's dashboards, deployed under their own
#                          uids so a reviewer can look at the thing rather than
#                          at a JSON diff. Disposable: the workflow creates and
#                          deletes them, and this root owns the folder and its
#                          permissions but nothing inside it. That is the only
#                          mixed-ownership boundary here, and it holds because
#                          nothing durable lives on the far side.
#
#                          A preview lives exactly as long as its pull request.
#                          Every push redeploys it at the new head, a force-push
#                          included, and closing or merging deletes it. Nothing
#                          else expires one, so there is no sweeper to write and
#                          no preview outliving what it previews.
#
# Nesting is only safe in this direction. Grafana inherits folder permissions
# downward and has no deny: "if the parent is accessible then the subfolders are
# accessible as well (due to inheritance)" (grafana, folderimpl/folder.go). Put
# Edit on the parent and every child has Edit, whatever its own permissions say,
# and the alerts cordon dissolves while still looking right in the UI. So the
# parent is the restrictive one and Dashboards adds Edit back.
#
# The failure mode if Grafana does not resolve a child's Edit over an inherited
# View the way this assumes is that the Dashboards folder is read-only in the UI
# -- annoying, and the safe direction to be wrong in. Check it after the first
# apply by saving a trivial edit to a dashboard.
#
# "Admin" below is the folder permission level, not the org basic role. The
# accounts that hold it are created with "No basic role": no org-level permission
# of any kind, and nothing outside this tree. Folder Admin rather than Edit
# because grafana_folder_permission writes a folder's permission set, and doing
# that needs Admin on the folder -- an account with Edit could write the
# dashboards it manages but not the permissions it declares.
#
# Every grant a Forge folder carries is declared here, including the ones for
# accounts this root does not otherwise mention. The provider is explicit that
# the resource "manages the entire set of permissions for a folder. Permissions
# that aren't specified when applying this resource will be removed", so a grant
# added in the UI survives only until the next apply. `user_id` takes a service
# account id as readily as a person's.
#
# Grafana org admins bypass folder permissions, so all of this is a guardrail
# rather than a lock.

variable "parent_folder_uid" {
  description = "Uid of the Forge folder every folder here nests under. The one folder made by hand: creating a folder at the root needs folders:create scoped to folders:uid:general, which no folder-scoped grant confers, so a person with org Admin makes it once. The three children below are created by this root, because creating a folder under a parent is authorised against the parent and folder Admin carries folders:write. See main.tf's header. Its uid is whatever the UI generated rather than a chosen one; read it off the folder's URL. Not a secret."
  type        = string
}

variable "sync_service_account_id" {
  description = "Numeric id of the forge-sync service account, which holds View on the tree and nothing else. The sync workflow reads dashboards back out of Grafana to raise the pull request that returns a UI edit to git, so read is all it needs. It is declared here because grafana_folder_permission writes the folder's whole permission set: a grant added by hand would be removed on the next apply. Not a secret."
  type        = string
}

variable "previews_service_account_id" {
  description = "Numeric id of the forge-previews service account, which holds Admin on the previews folder and nothing else. The preview workflow runs on pull_request, so its credential is reachable by any action a pull request brings with it; scoped this way the worst case is a trashed preview. Not a secret."
  type        = string
}

# The parent is not declared as a grafana_folder: it is made by hand and this
# root never needs to create or rename it. Its permissions are another matter --
# they are what every child inherits, so leaving them to whatever the UI set at
# creation would put the tree's floor outside git. grafana_folder_permission
# takes a uid directly and needs no managed folder resource.
resource "grafana_folder_permission" "parent" {
  folder_uid = var.parent_folder_uid

  permissions {
    user_id    = var.terraform_service_account_id
    permission = "Admin"
  }

  # On the parent, so it reaches every child. The sync workflow only reads: it
  # exports what the UI holds and opens a pull request against the committed
  # JSON. Writing back is this root's job, after a human has merged that.
  permissions {
    user_id    = var.sync_service_account_id
    permission = "View"
  }

  # View, not Edit. This is the floor: whatever is granted here, no child can
  # withhold. Dashboards adds Edit on top of it.
  permissions {
    role       = "Editor"
    permission = "View"
  }

  permissions {
    role       = "Viewer"
    permission = "View"
  }
}

resource "grafana_folder" "dashboards" {
  uid               = "forge"
  title             = "Dashboards"
  parent_folder_uid = var.parent_folder_uid
}

# The one child that widens what it inherits. Editing these in the UI is the
# supported path, and the sync workflow is what makes it safe rather than a
# permission is.
resource "grafana_folder_permission" "dashboards" {
  folder_uid = grafana_folder.dashboards.uid

  permissions {
    user_id    = var.terraform_service_account_id
    permission = "Admin"
  }

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
  uid               = "forge-alerts"
  title             = "Alerts (managed in git)"
  parent_folder_uid = var.parent_folder_uid
}

# Adds nothing a person can use, so Editor and Viewer are View by inheritance
# from the parent. Grafana marks file-provisioned and Git Sync resources
# read-only and refuses to save over them; a rule written through the HTTP API,
# which is what this provider uses, is an ordinary rule. The permission is the
# only thing stopping a UI edit, so the title says where the truth is.
resource "grafana_folder_permission" "alerts" {
  folder_uid = grafana_folder.alerts.uid

  permissions {
    user_id    = var.terraform_service_account_id
    permission = "Admin"
  }
}

resource "grafana_folder" "previews" {
  uid               = "forge-previews"
  title             = "Previews (disposable)"
  parent_folder_uid = var.parent_folder_uid
}

# Read-only for people by inheritance, on top of the spec.editable = false that
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
    user_id    = var.terraform_service_account_id
    permission = "Admin"
  }

  permissions {
    user_id    = var.previews_service_account_id
    permission = "Admin"
  }
}
