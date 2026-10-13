# Where Forge's alerts go: a notification policy tree of Forge's own. Every rule
# in alerts.tf names it in notification_settings.policy, so none of them reaches
# the stack's default tree, which FilOne's routes live in and which stays in the
# UI.
#
# A named tree is a separate object from the default one, so owning it here
# takes nothing of FilOne's. grafana_notification_policy is still not used: it
# manages the default tree, the whole of it, as one resource.
#
# The tree has only defaults, no child routes. Everything goes to the contact
# point for the IRM integration Forge shares with FilOne, and IRM's own routes,
# kept in the IRM UI, decide what pages: a critical alert on production, or a
# critical alert with no stage, escalates; everything else notifies once.
# Grouping by stage and severity is what lets them: each notification IRM
# receives carries one value of each.
#
# Writing the tree needs two things outside this root:
#
#   - the alertingMultiplePolicies feature toggle on the stack, which the
#     provider's documentation for this resource requires (Grafana 13.1 or
#     later); and
#   - on forge-terraform, the fixed role `fixed:alerting.routes:writer`
#     ("Notification Policies Writer"), granted for this tree on 2026-10-13.
#     Grafana's access-role docs scope it to routingtrees:*, every tree in the
#     stack, so it can reach the default tree and FilOne's routes too; this root
#     declares only its own. Grafana also defines a narrower
#     `fixed:alerting.managed-routes:creator` ("Notification Policies Creator"),
#     which may grant a tree's creator rights on that tree alone; untried here.
#
# The contact point is named, not declared. grafana_contact_point would keep its
# integration's URL or token in this state.
variable "forge_contact_point" {
  description = "Name of the contact point Forge's alerts are delivered to: the one for the IRM integration Forge shares with FilOne. It is made in the UI, and its name is not a secret."
  type        = string
}

# The tree's uid, which each rule's notification_settings.policy names and the
# rule groups' postconditions in alerts.tf compare it with.
locals {
  forge_policy = grafana_apps_notifications_routingtree_v1beta1.forge.metadata.uid
}

resource "grafana_apps_notifications_routingtree_v1beta1" "forge" {
  metadata {
    uid = "forge"
  }

  spec {
    # Terraform owns the tree; a change made in the UI is refused rather than
    # overwritten at the next apply.
    disable_provenance = false

    defaults {
      receiver = var.forge_contact_point
      group_by = ["alertname", "node", "stage", "severity"]
    }
  }
}
