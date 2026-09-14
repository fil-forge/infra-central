# The role CloudWatch Logs assumes to write a stage's log events into the
# stage's Firehose, and the Firehose's ARN, derived rather than looked up.
#
# The Firehose itself is created by the regional bootstrap root
# (modules/telemetry), because it holds the Grafana push token and this root is
# applied by CI. Its name is a convention both sides state, `fc-<stage>-logs`,
# so this module can build the ARN from the stage, account and region without a
# data source. That matters twice over: the CI plan role holds no firehose:*
# action to look one up with, and a data source would fail the plan of a stage
# whose bootstrap has not been applied yet, where a bad ARN fails only the apply
# of the subscription filters, with an error that names the missing stream.
#
# One role per stage rather than one per log group. CloudWatch Logs is a
# single principal and the policy names a single destination, so there is
# nothing a per-group role would narrow.

locals {
  name         = "fc-${var.stage}"
  firehose_arn = "arn:aws:firehose:${var.region}:${var.account_id}:deliverystream/${local.name}-logs"
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["logs.amazonaws.com"]
    }

    # Both conditions, as AWS documents for this principal: the account keeps
    # another account's log groups from assuming the role, and the ARN keeps it
    # to CloudWatch Logs in this region.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:logs:${var.region}:${var.account_id}:*"]
    }
  }
}

data "aws_iam_policy_document" "write" {
  statement {
    sid       = "WriteToStageFirehose"
    actions   = ["firehose:PutRecord", "firehose:PutRecordBatch"]
    resources = [local.firehose_arn]
  }
}

resource "aws_iam_role" "this" {
  name               = "${local.name}-logs-to-firehose"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy" "this" {
  name   = "write-to-firehose"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.write.json
}
