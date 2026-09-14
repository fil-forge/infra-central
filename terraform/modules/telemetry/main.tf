# Telemetry egress to Grafana Cloud: one Firehose per stage carrying CloudWatch
# Logs to Loki, and one metric stream per account and region carrying
# CloudWatch metrics to Prometheus.
#
# Everything here holds the Grafana push token, which is why it lives in the
# regional bootstrap root and not in a stage root. A Firehose stores its HTTP
# endpoint access key as an ordinary attribute, so the token lands in whichever
# state applies it. The bootstrap roots are applied from a laptop, and their
# state is the one the CI plan role cannot read; putting the token there keeps
# the property modules/github-actions-iam is built on, that a pull request's
# plan job reaches no secret. The stage roots create only what needs no token:
# the subscription filters and the role CloudWatch Logs assumes to write here,
# addressing each Firehose by the name convention below.
#
# Logs are per stage so each line can carry the stage as a label. Metrics are
# per account and region because that is the scope of a metric stream: it ships
# every metric in the namespaces it names, whatever created the resource, so a
# second stream naming the same namespaces would ship every sample twice.
#
# ── The metric stream shares the account with FilOne's ─────────────────────
#
# fil-one/infra deploys `filone-infra-<stage>-MetricStream` into these same two
# accounts, and it already ships AWS/Lambda and AWS/DynamoDB account-wide, which
# covers the provision Lambda and the delegator's two tables. Those namespaces
# are deliberately absent from the include filter below: naming them here would
# duplicate every FilOne Lambda's metrics as well as ours. If FilOne's stream is
# ever removed or narrowed, add the two namespaces here. fil-one/infra's
# sst.config.ts carries a comment pointing back at this dependency.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region

  # What a stage root derives, so it has to be exactly this shape. See
  # modules/platform/log-forwarding.
  log_firehose_name = { for stage in var.stages : stage => "fc-${stage}-logs" }

  metrics_name = "forge-central-metrics"

  # Metric names arrive in Grafana as aws_<namespace>_<metric>_<statistic>.
  # AWS/Firehose is here so the pipeline reports on itself: a stream whose
  # DeliveryToHttpEndpoint.DataFreshness keeps climbing is the signal that logs
  # or metrics have stopped arriving, and it covers FilOne's Firehoses in the
  # account as well. The metrics stream carries its own health series, so when
  # it stalls the signal is that series going stale; docs/observability.md says
  # where to read it then.
  metric_namespaces = [
    "AWS/ECS",
    "AWS/ApplicationELB",
    "AWS/RDS",
    "AWS/NATGateway",
    "AWS/Firehose",
  ]
}

# ── Failed-batch backup ──────────────────────────────────────────────────────
#
# A Firehose that cannot deliver a batch to Grafana writes it here instead of
# dropping it. One bucket for every stream in the module, with a prefix per
# stream. Objects expire after two weeks: a failed batch is worth keeping long
# enough for someone to notice the delivery metric and replay it, and no longer.
#
# The bucket and the two IAM roles below carry the region in their names.
# Bucket names and IAM are account-global, and the README tells a second region
# to copy this root as it is, so a name without the region would already be
# taken by the first region's state.

resource "aws_s3_bucket" "backup" {
  bucket = "forge-central-firehose-backup-${local.account_id}-${local.region}"

  # Nothing here is irreplaceable, so a destroy empties the bucket rather than
  # failing on it.
  force_destroy = true

  tags = { Name = "forge-central-firehose-backup-${local.region}" }
}

resource "aws_s3_bucket_public_access_block" "backup" {
  bucket                  = aws_s3_bucket.backup.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id

  rule {
    id     = "expire-failed-batches"
    status = "Enabled"

    filter {}

    expiration {
      days = 14
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# ── Firehose's own error log ─────────────────────────────────────────────────
#
# Where a Firehose says why a delivery failed: an HTTP status from Grafana, a
# rejected token, a malformed batch. One group, one stream per Firehose. This is
# the first place to look when the backup bucket is not empty.

resource "aws_cloudwatch_log_group" "firehose" {
  name              = "/forge-central/firehose"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_stream" "logs" {
  for_each = local.log_firehose_name

  name           = each.value
  log_group_name = aws_cloudwatch_log_group.firehose.name
}

resource "aws_cloudwatch_log_stream" "metrics" {
  name           = local.metrics_name
  log_group_name = aws_cloudwatch_log_group.firehose.name
}

# ── The role every Firehose here runs as ────────────────────────────────────

data "aws_iam_policy_document" "firehose_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["firehose.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

data "aws_iam_policy_document" "firehose" {
  statement {
    sid       = "ListBackupBucket"
    actions   = ["s3:GetBucketLocation", "s3:ListBucket", "s3:ListBucketMultipartUploads"]
    resources = [aws_s3_bucket.backup.arn]
  }

  statement {
    sid       = "WriteFailedBatches"
    actions   = ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload"]
    resources = ["${aws_s3_bucket.backup.arn}/*"]
  }

  statement {
    sid       = "WriteOwnErrorLog"
    actions   = ["logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.firehose.arn}:*"]
  }
}

resource "aws_iam_role" "firehose" {
  name               = "forge-central-firehose-${local.region}"
  assume_role_policy = data.aws_iam_policy_document.firehose_assume.json
}

resource "aws_iam_role_policy" "firehose" {
  name   = "backup-and-error-log"
  role   = aws_iam_role.firehose.id
  policy = data.aws_iam_policy_document.firehose.json
}

# ── Logs: one Firehose per stage, to Loki ───────────────────────────────────
#
# CloudWatch Logs hands a subscription filter's events to the Firehose as
# gzipped JSON envelopes; Grafana's endpoint unpacks them itself, so the stream
# transforms nothing. Grafana keeps the envelope's log group as the
# `aws_log_group` label and the account as `account_id`, and turns every
# `lbl_`-prefixed common attribute into a label with the prefix removed. Loki
# then derives `service_name` from `service`. That is what makes one Firehose
# per stage enough: `{aws_log_group="/forge-central/dev/hilt"}` selects a
# service, `{service_name="forge-central-dev"}` a stage. docs/observability.md
# has the rest of the label glossary.

resource "aws_kinesis_firehose_delivery_stream" "logs" {
  for_each = local.log_firehose_name

  name        = each.value
  destination = "http_endpoint"

  http_endpoint_configuration {
    url        = var.grafana_logs_url
    name       = "grafana-cloud-loki"
    access_key = "${var.grafana_logs_user}:${var.grafana_push_token}"
    role_arn   = aws_iam_role.firehose.arn

    # A minute or a megabyte, whichever comes first. Matches what FilOne runs.
    buffering_interval = 60
    buffering_size     = 1

    s3_backup_mode = "FailedDataOnly"

    s3_configuration {
      role_arn   = aws_iam_role.firehose.arn
      bucket_arn = aws_s3_bucket.backup.arn
      prefix     = "${each.value}/"
    }

    request_configuration {
      content_encoding = "GZIP"

      common_attributes {
        name  = "lbl_environment"
        value = each.key
      }

      common_attributes {
        name  = "lbl_service"
        value = "forge-central-${each.key}"
      }
    }

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = aws_cloudwatch_log_group.firehose.name
      log_stream_name = aws_cloudwatch_log_stream.logs[each.key].name
    }
  }

  tags = { Name = each.value }

  # Firehose checks the role can reach the backup bucket and the error log when
  # the stream is created, and the role reference alone orders this after the
  # role, not after its policy.
  depends_on = [aws_iam_role_policy.firehose]
}

# ── Metrics: one Firehose and one stream per account and region ─────────────

resource "aws_kinesis_firehose_delivery_stream" "metrics" {
  name        = local.metrics_name
  destination = "http_endpoint"

  http_endpoint_configuration {
    url        = var.grafana_metrics_url
    name       = "grafana-cloud-prometheus"
    access_key = "${var.grafana_metrics_user}:${var.grafana_push_token}"
    role_arn   = aws_iam_role.firehose.arn

    buffering_interval = 60
    buffering_size     = 1

    s3_backup_mode = "FailedDataOnly"

    s3_configuration {
      role_arn   = aws_iam_role.firehose.arn
      bucket_arn = aws_s3_bucket.backup.arn
      prefix     = "${local.metrics_name}/"
    }

    request_configuration {
      content_encoding = "GZIP"
    }

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = aws_cloudwatch_log_group.firehose.name
      log_stream_name = aws_cloudwatch_log_stream.metrics.name
    }
  }

  tags = { Name = local.metrics_name }

  # Same reason as the logs Firehoses above.
  depends_on = [aws_iam_role_policy.firehose]
}

data "aws_iam_policy_document" "metric_stream_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["streams.metrics.cloudwatch.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

data "aws_iam_policy_document" "metric_stream" {
  statement {
    sid       = "WriteToFirehose"
    actions   = ["firehose:PutRecord", "firehose:PutRecordBatch"]
    resources = [aws_kinesis_firehose_delivery_stream.metrics.arn]
  }
}

resource "aws_iam_role" "metric_stream" {
  name               = "forge-central-metric-stream-${local.region}"
  assume_role_policy = data.aws_iam_policy_document.metric_stream_assume.json
}

resource "aws_iam_role_policy" "metric_stream" {
  name   = "write-to-firehose"
  role   = aws_iam_role.metric_stream.id
  policy = data.aws_iam_policy_document.metric_stream.json
}

# opentelemetry1.0 is the format Grafana's aws-metrics endpoint accepts. Every
# metric in each namespace is included: a metric stream cannot filter by
# resource or tag, so this is account-wide by construction, and there is no
# per-stage variant to have.
resource "aws_cloudwatch_metric_stream" "this" {
  name          = local.metrics_name
  role_arn      = aws_iam_role.metric_stream.arn
  firehose_arn  = aws_kinesis_firehose_delivery_stream.metrics.arn
  output_format = "opentelemetry1.0"

  dynamic "include_filter" {
    for_each = toset(local.metric_namespaces)

    content {
      namespace = include_filter.value
    }
  }

  # The stream needs the policy in place before it can write, and it validates
  # that on creation.
  depends_on = [aws_iam_role_policy.metric_stream]
}
