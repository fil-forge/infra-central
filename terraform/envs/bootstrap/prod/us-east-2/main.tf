# Regional bootstrap for the prod account in us-east-2: the ECR repository the
# prod stage pulls its provision image from, the Firehoses and metric stream
# that carry the stage's logs and metrics to Grafana Cloud, the KMS keys of
# its Aurora cluster and its OpenBao seal, and the site-to-site VPN that the
# compatibility server's appliances reach the pandora database through.
#
# The non-prod copy of this directory carries the full explanation of why the
# state bucket and the CI roles are not here but in ../account/, why this root is
# applied by hand, and which three Grafana values it takes. Prod ships to the
# same Grafana Cloud stack as the non-prod stages, so the values are the same
# 1Password items.
#
# It cannot be applied before ../account/, which creates the bucket this root's
# backend names.

provider "aws" {
  region = "us-east-2"

  allowed_account_ids = [module.constants.prod_account_id]
}

module "constants" {
  source = "../../../../modules/shared/constants"
}

module "ecr" {
  source = "../../../../modules/ecr"
}

# The prod Aurora cluster's key. It lives here rather than in the platform root
# because a cluster cannot change its key without a restore into a new cluster,
# and because a snapshot is readable only while its key is: a key created by
# the platform root would be scheduled for deletion by any destroy of that
# root, taking the final snapshot with it.
#
# Multi-region because the flag is fixed when a key is created. Backup copies
# in the DR region (FIL-1298) and the Global Database secondary (FIL-1297)
# need a replica of this key there. FIL-1445 adds that replica and the policy
# that stops anyone but a break-glass role from deleting or disabling the key.
resource "aws_kms_key" "aurora" {
  description             = "Forge prod: the Aurora cluster"
  multi_region            = true
  enable_key_rotation     = true
  deletion_window_in_days = 30

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "aurora" {
  name          = module.constants.prod_aurora_key_alias
  target_key_id = aws_kms_key.aurora.key_id
}

# The key prod OpenBao seals its storage with. Dev and staging get theirs from
# the platform module, which destroys it with the stage. Prod's lives here
# because OpenBao's storage, in the Aurora cluster, outlives the platform root in
# the cluster's final snapshot and its DR copies, and is unreadable without
# this key.
#
# Multi-region because the flag is fixed when a key is created, and changing
# the key later means migrating a running OpenBao to a new seal. After losing
# us-east-2, the platform root applied in the DR region unseals the Global
# Database secondary's copy of OpenBao with a replica of this key. FIL-1445 adds
# that replica, the same alias on it in the DR region (an alias does not follow
# a key into its replicas), and the same deletion guard as the Aurora key's.
resource "aws_kms_key" "openbao_seal" {
  description             = "Forge prod: the OpenBao seal"
  multi_region            = true
  enable_key_rotation     = true
  deletion_window_in_days = 30

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "openbao_seal" {
  name          = module.constants.prod_openbao_seal_key_alias
  target_key_id = aws_kms_key.openbao_seal.key_id
}

# One gateway per stage that has compatibility server sites, and one VPN
# connection per site. Adding a site to the constants module and applying this
# root by hand comes before the platform root can attach the gateway; see
# docs/compat-server-vpn.md.
module "compat_vpn" {
  source   = "../../../../modules/compat-vpn"
  for_each = toset(module.constants.prod_stages)

  stage        = each.key
  sites        = module.constants.compat_server_sites[each.key]
  private_cidr = module.constants.compat_server_private_cidr
}

module "telemetry" {
  source = "../../../../modules/telemetry"

  stages = module.constants.prod_stages

  grafana_logs_user    = var.grafana_logs_user
  grafana_metrics_user = var.grafana_metrics_user
  grafana_push_token   = var.grafana_push_token
}

variable "grafana_logs_user" {
  description = "Loki instance id of the Grafana Cloud stack. GRAFANA_LOGS_USER in 1Password; TF_VAR_grafana_logs_user."
  type        = string
}

variable "grafana_metrics_user" {
  description = "Prometheus instance id of the Grafana Cloud stack. GRAFANA_METRICS_USER in 1Password; TF_VAR_grafana_metrics_user."
  type        = string
}

variable "grafana_push_token" {
  description = "Grafana Cloud access policy token with logs:write and metrics:write. GRAFANA_CLOUD_PUSH_TOKEN in 1Password; TF_VAR_grafana_push_token."
  type        = string
  sensitive   = true
}

output "provision_repository_url" {
  value = module.ecr.provision_repository_url
}

output "log_firehose_arns" {
  value = module.telemetry.log_firehose_arns
}

output "metric_stream_name" {
  value = module.telemetry.metric_stream_name
}

output "firehose_backup_bucket" {
  value = module.telemetry.backup_bucket_name
}

output "compat_vpn_sites" {
  description = "Per stage, each compatibility server site's VPN connection, tunnel addresses and pre-shared key ARN."
  value       = { for stage, vpn in module.compat_vpn : stage => vpn.sites }
}
