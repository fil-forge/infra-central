# Regional bootstrap for the non-prod account in us-east-2: the ECR repositories
# every non-prod stage in this region pulls its images from, and the Firehoses
# and metric stream that carry the stages' logs and metrics to Grafana Cloud.
#
# One of these directories per account and region, because both things it holds
# are scoped that way: an ECR repository serves only functions in the same
# account and region, and a metric stream ships the metrics of one account in
# one region. The account-wide half of the bootstrap — the state bucket and the
# CI roles — is in ../account/, and is deliberately not here: an S3 bucket name
# is global and IAM is not regional, so a copy of this directory for a second
# region would collide with the first on both.
#
# It is applied by hand rather than by CI, like the account root next door, for
# two reasons. The image the repository makes room for is pushed by hand too:
# the platform root requires a digest, `make publish` cannot push without a
# repository, and Terraform cannot create the repository as part of the same
# apply that consumes the image. And the telemetry module holds the Grafana push
# token in its state, which is a state the CI plan role must never be able to
# read; see modules/telemetry.
#
# Applying it takes three values from the Grafana Cloud stack, none of them
# committed:
#
#   TF_VAR_grafana_logs_user      Loki instance id
#   TF_VAR_grafana_metrics_user   Prometheus instance id
#   TF_VAR_grafana_push_token     access policy token, logs:write + metrics:write
#
# Adding a region means copying this directory and changing two things, the
# provider region below and the backend key in versions.tofu. Nothing else in the
# tree is region-aware, so there is no shared list to keep in step. Adding a
# stage means adding it to the constants module, which both bootstrap roots read.

provider "aws" {
  region = "us-east-2"

  # A repository created in the wrong account is invisible until a stage's
  # Lambda fails to pull from it, so name the account this root belongs to and
  # let a mismatch fail at plan time instead.
  allowed_account_ids = [module.constants.nonprod_account_id]
}

module "constants" {
  source = "../../../../modules/shared/constants"
}

module "ecr" {
  source = "../../../../modules/ecr"
}

module "telemetry" {
  source = "../../../../modules/telemetry"

  stages = module.constants.nonprod_stages

  grafana_logs_user    = var.grafana_logs_user
  grafana_metrics_user = var.grafana_metrics_user
  grafana_push_token   = var.grafana_push_token
}

variable "grafana_logs_user" {
  description = "Loki instance id of the Grafana Cloud stack. TF_VAR_grafana_logs_user."
  type        = string
}

variable "grafana_metrics_user" {
  description = "Prometheus instance id of the Grafana Cloud stack. TF_VAR_grafana_metrics_user."
  type        = string
}

variable "grafana_push_token" {
  description = "Grafana Cloud access policy token with logs:write and metrics:write. TF_VAR_grafana_push_token."
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
