# Regional bootstrap for the prod account in us-east-2: the ECR repository the
# prod stage pulls its provision image from, the Firehoses and metric stream
# that carry the stage's logs and metrics to Grafana Cloud, and the KMS keys of
# its Aurora cluster and its OpenBao seal, with their replicas in the DR region,
# and the EventBridge rules that tell Grafana when one of those keys changes.
#
# Apply it with -var break_glass=true whenever a key's policy or replica
# changes, so both providers act as the break-glass role from ../account/; see
# docs/region-loss.md.
#
# The non-prod copy of this directory carries the full explanation of why the
# state bucket and the CI roles are not here but in ../account/, why this root is
# applied by hand, and which three Grafana values it takes. Prod ships to the
# same Grafana Cloud stack as the non-prod stages, so the values are the same
# 1Password items.
#
# It cannot be applied before ../account/, which creates the bucket this root's
# backend names.

# The key guard below refuses PutKeyPolicy and ReplicateKey to everyone but the
# break-glass role, so an apply that changes a key's policy or replica must run
# as that role. With this set, each provider assumes it from the operator's own
# SSO credentials and keeps the role's credentials in memory. The state backend
# keeps the SSO credentials.
variable "break_glass" {
  description = "Run both providers as the KMS break-glass role. Needed when a key's policy or replica changes; only the people the role trusts can use it."
  type        = bool
  default     = false
}

locals {
  kms_break_glass_role_arn = "arn:aws:iam::${module.constants.prod_account_id}:role/${module.constants.prod_kms_break_glass_role_name}"
}

provider "aws" {
  region = "us-east-2"

  allowed_account_ids = [module.constants.prod_account_id]

  dynamic "assume_role" {
    for_each = var.break_glass ? [local.kms_break_glass_role_arn] : []
    content {
      role_arn     = assume_role.value
      session_name = "kms-break-glass"
    }
  }
}

# The DR region, for the replicas of the two keys below.
provider "aws" {
  alias  = "dr"
  region = module.constants.dr_region

  allowed_account_ids = [module.constants.prod_account_id]

  dynamic "assume_role" {
    for_each = var.break_glass ? [local.kms_break_glass_role_arn] : []
    content {
      role_arn     = assume_role.value
      session_name = "kms-break-glass"
    }
  }
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
# in the DR region (FIL-1298) and the Global Database secondary (FIL-1297) use
# its replica there.
resource "aws_kms_key" "aurora" {
  description                        = "Forge prod: the Aurora cluster"
  multi_region                       = true
  enable_key_rotation                = true
  deletion_window_in_days            = 30
  policy                             = data.aws_iam_policy_document.guarded_key.json
  bypass_policy_lockout_safety_check = false

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "aurora" {
  name          = module.constants.prod_aurora_key_alias
  target_key_id = aws_kms_key.aurora.key_id
}

# A replica shares the key material but has its own policy, so it takes the
# same guard. An alias does not follow a key into its replicas, so the replica
# gets the same alias in its own region.
resource "aws_kms_replica_key" "aurora" {
  provider = aws.dr

  description                        = "Forge prod: the Aurora cluster (DR replica)"
  primary_key_arn                    = aws_kms_key.aurora.arn
  deletion_window_in_days            = 30
  policy                             = data.aws_iam_policy_document.guarded_key.json
  bypass_policy_lockout_safety_check = false

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "aurora_dr" {
  provider = aws.dr

  name          = module.constants.prod_aurora_key_alias
  target_key_id = aws_kms_replica_key.aurora.key_id
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
# Database secondary's copy of OpenBao with the replica below.
resource "aws_kms_key" "openbao_seal" {
  description                        = "Forge prod: the OpenBao seal"
  multi_region                       = true
  enable_key_rotation                = true
  deletion_window_in_days            = 30
  policy                             = data.aws_iam_policy_document.guarded_key.json
  bypass_policy_lockout_safety_check = false

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "openbao_seal" {
  name          = module.constants.prod_openbao_seal_key_alias
  target_key_id = aws_kms_key.openbao_seal.key_id
}

resource "aws_kms_replica_key" "openbao_seal" {
  provider = aws.dr

  description                        = "Forge prod: the OpenBao seal (DR replica)"
  primary_key_arn                    = aws_kms_key.openbao_seal.arn
  deletion_window_in_days            = 30
  policy                             = data.aws_iam_policy_document.guarded_key.json
  bypass_policy_lockout_safety_check = false

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "openbao_seal_dr" {
  provider = aws.dr

  name          = module.constants.prod_openbao_seal_key_alias
  target_key_id = aws_kms_replica_key.openbao_seal.key_id
}

# The policy of all four keys. Losing either key makes the Aurora cluster, its
# snapshots and OpenBao's storage unreadable, so only the break-glass role and
# the account's root user may take the actions that end a key's use, or that
# would let someone else do so.
#
# The first statement is KMS's default: it lets IAM policies grant use of the
# key, which CI, the task roles and RDS rely on. Dropping it cuts them all off.
#
# The second denies everyone else the guarded actions. It names the exempt
# principals by ARN in a condition rather than as a principal, because KMS
# stores a named principal as the role's internal id: a recreated role would no
# longer match. The root user is exempt so that a wrong role ARN here cannot
# leave the policy uneditable. Every key keeps
# bypass_policy_lockout_safety_check false, so KMS refuses a policy that would
# stop its caller from editing it again.
#
# The guarded actions are the ones that stop a key working, keep it from being
# fixed, or move its alias, which the platform root finds the key by. EnableKey
# and CancelKeyDeletion are left open so anyone can undo a disable or a
# scheduled deletion. No action that uses the key may be guarded; the check
# below fails the plan if one is.
locals {
  kms_break_glass_principals = [
    local.kms_break_glass_role_arn,
    "arn:aws:iam::${module.constants.prod_account_id}:root",
  ]

  kms_guarded_actions = [
    "kms:DeleteAlias",
    "kms:DisableKey",
    "kms:PutKeyPolicy",
    "kms:ReplicateKey",
    "kms:ScheduleKeyDeletion",
    "kms:UpdateAlias",
    "kms:UpdatePrimaryRegion",
  ]
}

data "aws_iam_policy_document" "guarded_key" {
  statement {
    sid       = "EnableIamPolicies"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${module.constants.prod_account_id}:root"]
    }
  }

  statement {
    sid       = "GuardKeyLifecycle"
    effect    = "Deny"
    actions   = local.kms_guarded_actions
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "ArnNotEquals"
      variable = "aws:PrincipalArn"
      values   = local.kms_break_glass_principals
    }
  }

  lifecycle {
    postcondition {
      condition = alltrue([
        for action in local.kms_guarded_actions :
        !strcontains(action, "*") && !contains([
          "kms:CreateGrant",
          "kms:Decrypt",
          "kms:DescribeKey",
          "kms:Encrypt",
          "kms:GenerateDataKey",
          "kms:GenerateDataKeyWithoutPlaintext",
          "kms:ReEncryptFrom",
          "kms:ReEncryptTo",
        ], action)
      ])
      error_message = "The key guard denies an action Aurora or OpenBao needs to use the key, or a wildcard. Guarding it would stop the cluster or the seal."
    }
  }
}

module "telemetry" {
  source = "../../../../modules/telemetry"

  stages = module.constants.prod_stages

  grafana_logs_user    = var.grafana_logs_user
  grafana_metrics_user = var.grafana_metrics_user
  grafana_push_token   = var.grafana_push_token
}

# ── Guarded key changes, to Grafana ──────────────────────────────────────────
#
# KMS publishes no metric for a key's state, so on-call hears of a guarded
# action on the four keys from CloudTrail: EventBridge matches the call in the
# region it was made in, the DR region forwards its matches here, and a rule
# here writes both regions' matches to a log group that ships to Grafana like
# the services' logs. The Grafana root's alerts.tf pages on a call that
# succeeded and notifies on one the guard denied.
#
# The pattern names the keys and aliases rather than matching every KMS call,
# because the account holds other teams' keys. A call can name a key by id, ARN,
# alias or alias ARN, and CloudTrail records the resolved key in `resources`, so
# the pattern accepts any of them in either place. ReplicateKey is guarded but
# left out: it adds a replica and takes nothing away.
locals {
  kms_guarded_keys    = [aws_kms_key.aurora, aws_kms_key.openbao_seal, aws_kms_replica_key.aurora, aws_kms_replica_key.openbao_seal]
  kms_guarded_aliases = [aws_kms_alias.aurora, aws_kms_alias.openbao_seal, aws_kms_alias.aurora_dr, aws_kms_alias.openbao_seal_dr]

  kms_guarded_key_names = distinct(concat(
    [for key in local.kms_guarded_keys : key.key_id],
    [for key in local.kms_guarded_keys : key.arn],
    [for alias in local.kms_guarded_aliases : alias.name],
    [for alias in local.kms_guarded_aliases : alias.arn],
  ))

  kms_key_change_pattern = jsonencode({
    source      = ["aws.kms"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventName = ["DisableKey", "ScheduleKeyDeletion", "PutKeyPolicy", "DeleteAlias", "UpdateAlias", "UpdatePrimaryRegion"]
    }
    "$or" = [
      { detail = { resources = { ARN = local.kms_guarded_key_names } } },
      { detail = { requestParameters = { keyId = local.kms_guarded_key_names } } },
      { detail = { requestParameters = { aliasName = local.kms_guarded_key_names } } },
    ]
  })

  primary_event_bus_arn = "arn:aws:events:us-east-2:${module.constants.prod_account_id}:event-bus/default"
}

resource "aws_cloudwatch_event_rule" "kms_key_changes_dr" {
  provider = aws.dr

  name          = "fc-prod-kms-key-changes"
  description   = "Guarded calls on the prod Aurora and OpenBao seal keys, forwarded to us-east-2 for Grafana."
  event_pattern = local.kms_key_change_pattern
}

resource "aws_cloudwatch_event_target" "kms_key_changes_dr" {
  provider = aws.dr

  rule     = aws_cloudwatch_event_rule.kms_key_changes_dr.name
  arn      = local.primary_event_bus_arn
  role_arn = aws_iam_role.kms_key_changes_forwarder.arn
}

data "aws_iam_policy_document" "kms_key_changes_forwarder_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [module.constants.prod_account_id]
    }
  }
}

data "aws_iam_policy_document" "kms_key_changes_forwarder" {
  statement {
    actions   = ["events:PutEvents"]
    resources = [local.primary_event_bus_arn]
  }
}

resource "aws_iam_role" "kms_key_changes_forwarder" {
  name               = "fc-prod-kms-key-changes-forwarder"
  assume_role_policy = data.aws_iam_policy_document.kms_key_changes_forwarder_assume.json
}

resource "aws_iam_role_policy" "kms_key_changes_forwarder" {
  name   = "put-events-us-east-2"
  role   = aws_iam_role.kms_key_changes_forwarder.id
  policy = data.aws_iam_policy_document.kms_key_changes_forwarder.json
}

# Under /forge-central/prod/, so Loki finds it beside the stage's other groups.
resource "aws_cloudwatch_log_group" "kms_key_changes" {
  name              = "/forge-central/prod/kms-key-changes"
  retention_in_days = 30
}

# Matches this region's calls and the ones forwarded from the DR region, which
# keep their own `region`.
resource "aws_cloudwatch_event_rule" "kms_key_changes" {
  name          = "fc-prod-kms-key-changes"
  description   = "Guarded calls on the prod Aurora and OpenBao seal keys, to CloudWatch Logs for Grafana."
  event_pattern = local.kms_key_change_pattern
}

resource "aws_cloudwatch_event_target" "kms_key_changes" {
  rule = aws_cloudwatch_event_rule.kms_key_changes.name
  arn  = aws_cloudwatch_log_group.kms_key_changes.arn
}

# EventBridge writes to a log group only under a resource policy that lets it.
data "aws_iam_policy_document" "kms_key_changes_log_writer" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.kms_key_changes.arn}:*"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "delivery.logs.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.kms_key_changes.arn]
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "kms_key_changes" {
  policy_name     = "fc-prod-kms-key-changes"
  policy_document = data.aws_iam_policy_document.kms_key_changes_log_writer.json
}

# The stage's log role belongs to the prod platform root
# (modules/platform/log-forwarding), so its ARN is built from the name both
# roots state rather than looked up.
resource "aws_cloudwatch_log_subscription_filter" "kms_key_changes" {
  name            = "grafana-loki"
  log_group_name  = aws_cloudwatch_log_group.kms_key_changes.name
  filter_pattern  = ""
  destination_arn = module.telemetry.log_firehose_arns["prod"]
  role_arn        = "arn:aws:iam::${module.constants.prod_account_id}:role/fc-prod-logs-to-firehose"
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
