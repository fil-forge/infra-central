# ALB access logs. The bucket belongs to the load balancer rather than to the
# applications, which is why it lives here and not in the storage module.
#
# These are the only per-request record the stage keeps. CloudWatch has what
# each service chose to log about a request it accepted; this has the requests
# it rejected, the ones that never reached a service, and the client addresses
# behind both.

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "access_logs" {
  # Account suffix for global uniqueness, matching the storage module's buckets.
  bucket = "${local.name}-alb-logs-${data.aws_caller_identity.current.account_id}"

  # Same reasoning as the storage buckets: a stage that is allowed to be
  # destroyed empties this rather than failing the apply on a bucket someone
  # then has to purge by hand.
  force_destroy = !var.deletion_protection

  tags = { Name = "${local.name}-alb-logs" }
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  bucket                  = aws_s3_bucket.access_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# AES256 rather than the stage's KMS key: ALB log delivery supports only SSE-S3
# and silently fails to write when the bucket demands anything else.
resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id

  rule {
    id     = "expire"
    status = "Enabled"

    filter {}

    expiration {
      days = var.access_log_retention_days
    }
  }
}

# The account ID in the resource path is the whole point of the path: the log
# delivery principal is shared by every load balancer in the region, so a policy
# allowing writes anywhere under the bucket would let a load balancer in someone
# else's account log into ours. AWS documents this path form and documents no
# condition key to use in its place, and an undocumented condition the delivery
# service does not send would fail the same silent way a rejected encryption
# setting does.
data "aws_iam_policy_document" "access_logs" {
  statement {
    sid       = "ALBLogDelivery"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.access_logs.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]

    principals {
      type        = "Service"
      identifiers = ["logdelivery.elasticloadbalancing.amazonaws.com"]
    }
  }
}

resource "aws_s3_bucket_policy" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  policy = data.aws_iam_policy_document.access_logs.json
}
