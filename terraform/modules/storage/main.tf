# The object and key-value stores two services need, replacing smelt's MinIO
# and local DynamoDB.
#
# Sprue reaches S3 through its task role rather than static credentials, so its
# storage.s3.endpoint stays empty and the AWS default credential chain applies.
# That removes the MinIO root user and password from the design entirely.

locals {
  name = "forge-${var.stage}"

  # Sprue's three buckets. Names come from its defaults; the stage prefix and
  # account suffix make them globally unique.
  buckets = ["agent-message", "delegation", "upload-shards"]
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "this" {
  for_each = toset(local.buckets)

  bucket = "${local.name}-${each.key}-${data.aws_caller_identity.current.account_id}"
  tags   = { Name = "${local.name}-${each.key}" }
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each = aws_s3_bucket.this

  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "this" {
  for_each = aws_s3_bucket.this

  bucket = each.value.id

  versioning_configuration {
    status = "Enabled"
  }
}

# The delegator's two tables. It uses no Postgres at all, and creates neither
# table itself, so both have to exist before it starts.
resource "aws_dynamodb_table" "allow_list" {
  name         = "${local.name}-delegator-allow-list"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "did"

  attribute {
    name = "did"
    type = "S"
  }

  point_in_time_recovery {
    enabled = var.point_in_time_recovery
  }

  tags = { Name = "${local.name}-delegator-allow-list" }
}

resource "aws_dynamodb_table" "provider_info" {
  name         = "${local.name}-delegator-provider-info"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "provider"

  attribute {
    name = "provider"
    type = "S"
  }

  point_in_time_recovery {
    enabled = var.point_in_time_recovery
  }

  tags = { Name = "${local.name}-delegator-provider-info" }
}
