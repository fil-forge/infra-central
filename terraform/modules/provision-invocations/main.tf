# Who invoked a stage's provision Lambda. The function can write appliance
# root credentials to central OpenBao, and OpenBao's audit log names only the
# root token the function used, never the AWS principal behind the call. This
# module records each Invoke of the provision functions in this account and
# region, and ships it to Grafana beside the function's own log.
#
# The organization trail both accounts sit under (filecoin-foundation-org, in
# the Filecoin Foundation's management account) logs management events only,
# and a member account cannot change its selectors. So this module runs a trail
# of its own that logs data events and nothing else, and selects only the
# provision functions: every other function in the account, FilOne's included,
# stays out, and management events are not recorded twice.
#
# CloudTrail hands every event a trail logs to EventBridge as well, so a rule
# per stage copies that stage's Invokes into a log group that ships to Loki like
# any other. The bucket is the durable copy; the log group keeps what an
# investigation of a recent write needs. docs/observability.md has the lookup.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region

  # The name modules/platform/provision gives the function. Unqualified: the
  # stages invoke $LATEST, and the selector and rules below also accept an ARN
  # with a qualifier appended.
  function_arns = {
    for stage in var.stages : stage => "arn:aws:lambda:${local.region}:${local.account_id}:function:fc-${stage}-provision"
  }

  trail_name = "forge-central-provision-invocations"

  # Built from the name rather than read from the trail, because the bucket
  # policy names the trail and the trail cannot be created until the policy
  # lets it write.
  trail_arn = "arn:aws:cloudtrail:${local.region}:${local.account_id}:trail/${local.trail_name}"
}

# ── The trail's bucket ───────────────────────────────────────────────────────
#
# A trail must deliver to S3 even when EventBridge is all anyone reads. The
# region is in the name for the reason the telemetry module gives for its
# backup bucket: bucket names are global, and a second region copies this root
# as it is.

resource "aws_s3_bucket" "trail" {
  bucket = "forge-central-cloudtrail-${local.account_id}-${local.region}"

  tags = { Name = "forge-central-cloudtrail-${local.region}" }
}

resource "aws_s3_bucket_public_access_block" "trail" {
  bucket                  = aws_s3_bucket.trail.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "trail" {
  bucket = aws_s3_bucket.trail.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# A year: long enough to answer who stored a region's root credentials well
# after the log group has expired the event. The trail logs a few calls a day,
# so the cost of keeping them is negligible.
resource "aws_s3_bucket_lifecycle_configuration" "trail" {
  bucket = aws_s3_bucket.trail.id

  rule {
    id     = "expire-invocation-records"
    status = "Enabled"

    filter {}

    expiration {
      days = 365
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# The two statements AWS documents for a trail's bucket, each held to this
# trail by its ARN so no other trail can deliver here.
data "aws_iam_policy_document" "trail_bucket" {
  statement {
    sid       = "CloudTrailAclCheck"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.trail.arn]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }

  statement {
    sid       = "CloudTrailWrite"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.trail.arn}/AWSLogs/${local.account_id}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }
}

resource "aws_s3_bucket_policy" "trail" {
  bucket = aws_s3_bucket.trail.id
  policy = data.aws_iam_policy_document.trail_bucket.json

  # The policy would otherwise race the block, which rejects a policy it
  # considers public while it is being set up.
  depends_on = [aws_s3_bucket_public_access_block.trail]
}

# ── The trail ────────────────────────────────────────────────────────────────
#
# Single-region, because the functions are in this region only. One field
# selector on the ARN with two operators, which CloudTrail ORs: the exact
# function ARN, and the same ARN followed by a qualifier. AWS does not document
# which form an Invoke of `$LATEST`, a version or an alias carries, and the
# colon keeps the prefix from matching a different function whose name merely
# starts with this one's.

resource "aws_cloudtrail" "this" {
  name                          = local.trail_name
  s3_bucket_name                = aws_s3_bucket.trail.id
  is_multi_region_trail         = false
  include_global_service_events = false
  enable_log_file_validation    = true

  advanced_event_selector {
    name = "Invocations of the provision Lambdas"

    field_selector {
      field  = "eventCategory"
      equals = ["Data"]
    }

    field_selector {
      field  = "resources.type"
      equals = ["AWS::Lambda::Function"]
    }

    field_selector {
      field       = "resources.ARN"
      equals      = values(local.function_arns)
      starts_with = [for arn in values(local.function_arns) : "${arn}:"]
    }
  }

  depends_on = [aws_s3_bucket_policy.trail]
}

# ── Each stage's invocations, to Grafana ────────────────────────────────────
#
# One log group and rule per stage, under /forge-central/<stage>/ so Loki finds
# it beside the stage's other groups and the stage's own Firehose labels it.
# Dev and staging share this account, so one group would label one of them
# wrongly.

resource "aws_cloudwatch_log_group" "invocations" {
  for_each = toset(var.stages)

  name              = "/forge-central/${each.key}/provision-invocations"
  retention_in_days = 30
}

# A data event reaches EventBridge with the rule plainly enabled. The
# ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS state is for read-only
# management events, which this trail does not log.
resource "aws_cloudwatch_event_rule" "invocations" {
  for_each = toset(var.stages)

  name        = "fc-${each.key}-provision-invocations"
  description = "Invokes of fc-${each.key}-provision, to CloudWatch Logs for Grafana."

  event_pattern = jsonencode({
    source      = ["aws.lambda"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["lambda.amazonaws.com"]
      eventName   = ["Invoke"]
      resources = {
        ARN = [local.function_arns[each.key], { prefix = "${local.function_arns[each.key]}:" }]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "invocations" {
  for_each = toset(var.stages)

  rule = aws_cloudwatch_event_rule.invocations[each.key].name
  arn  = aws_cloudwatch_log_group.invocations[each.key].arn
}

# EventBridge writes to a log group only under a resource policy that lets it.
# One policy for every stage's group: an account holds at most ten.
data "aws_iam_policy_document" "invocations_log_writer" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [for group in aws_cloudwatch_log_group.invocations : "${group.arn}:*"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "delivery.logs.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [for rule in aws_cloudwatch_event_rule.invocations : rule.arn]
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "invocations" {
  policy_name     = local.trail_name
  policy_document = data.aws_iam_policy_document.invocations_log_writer.json
}

# The role belongs to the stage's platform root (modules/platform/log-forwarding),
# so its ARN is built from the name both roots state rather than looked up. A
# new account applies its platform root before this filter can be created:
# apply this root, then the stage, then this root again.
resource "aws_cloudwatch_log_subscription_filter" "invocations" {
  for_each = toset(var.stages)

  name            = "grafana-loki"
  log_group_name  = aws_cloudwatch_log_group.invocations[each.key].name
  filter_pattern  = ""
  destination_arn = var.log_firehose_arns[each.key]
  role_arn        = "arn:aws:iam::${local.account_id}:role/fc-${each.key}-logs-to-firehose"
}
