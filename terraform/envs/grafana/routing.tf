# The notification policy tree for Forge's alerts. Every rule in alerts.tf names
# it in notification_settings.policy.
#
# Writing the tree needs two things outside this root:
#
#   - Grafana 13.1 or later, where multiple policy trees are on by default; and
#   - on forge-terraform, the fixed role `fixed:alerting.routes:writer`
#     ("Notification Policies Writer").
#
# The contact point is named, not declared. grafana_contact_point would keep its
# integration's URL or token in this state.
variable "forge_contact_point" {
  description = "Name of the contact point Forge's alerts are delivered to: the one for the IRM integration Forge shares with FilOne. It is made in the UI, and its name is not a secret."
  type        = string
}

# The tree's uid, which each rule's notification_settings.policy names.
# scripts/check-alert-routing.sh fails plan-grafana on a rule that doesn't.
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
