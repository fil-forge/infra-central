# Regional bootstrap for the prod account in us-east-2: the ECR repository the
# prod stage pulls its provision image from, and the Firehoses and metric stream
# that carry the stage's logs and metrics to Grafana Cloud.
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
