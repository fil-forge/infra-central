# The object and key-value stores two services need, replacing smelt's MinIO
# and local DynamoDB.
#
# Sprue reaches S3 through its task role rather than static credentials: the
# apps module sets its storage.s3.endpoint empty, so the AWS default credential
# chain applies. That removes the MinIO root user and password from the design
# entirely.

locals {
  name = "fc-${var.stage}"

  # Sprue's two buckets. Names come from its defaults; the stage prefix and
  # account suffix make them globally unique.
  buckets = ["agent-message", "delegation"]
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "this" {
  for_each = toset(local.buckets)

  bucket = "${local.name}-${each.key}-${data.aws_caller_identity.current.account_id}"

  # A stage meant to be thrown away empties its buckets on destroy rather than
  # failing the apply and leaving them behind for someone to purge by hand.
  # Staging and prod keep it off, so destroying either means purging every
  # object version first.
  force_destroy = var.force_destroy

  tags = { Name = "${local.name}-${each.key}" }
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

# Sprue keeps each agent message and delegation here and nowhere else; Postgres
# holds only the index that points at them. A lost or overwritten object breaks
# receipt lookups and the dedup path, and a database restored to an earlier
# point in time needs the objects as they were at that point. Versioning keeps
# them for as long as the database's own recovery window.
#
# Keys are content addresses and sprue never deletes, so the only noncurrent
# versions in normal operation are identical copies left by a rewrite of the
# same message.
#
# Destroying this resource suspends versioning on the bucket, and a destroy
# removes it before attempting the bucket. With force_destroy off, the bucket
# delete then fails and leaves the bucket in place but unprotected.
# prevent_destroy rejects such a plan before anything is changed, here and on
# the lifecycle rule below. Destroying a versioned stage, or turning versioning
# off, therefore starts with removing this guard.
resource "aws_s3_bucket_versioning" "this" {
  for_each = var.versioning ? aws_s3_bucket.this : {}

  bucket = each.value.id

  versioning_configuration {
    status = "Enabled"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  for_each = aws_s3_bucket_versioning.this

  bucket = each.value.bucket

  lifecycle {
    prevent_destroy = true
  }

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.pitr_window_days
    }

    # A delete, such as a stage reset emptying the bucket, leaves a delete
    # marker in front of each object. Once the versions behind it expire, the
    # marker alone remains and is listed forever unless removed.
    expiration {
      expired_object_delete_marker = true
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# The delegator's two tables. It uses no Postgres at all, and creates neither
# table itself, so both have to exist before it starts.
resource "aws_dynamodb_table" "allow_list" {
  name                        = "${local.name}-delegator-allow-list"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "did"
  deletion_protection_enabled = var.deletion_protection

  attribute {
    name = "did"
    type = "S"
  }

  point_in_time_recovery {
    enabled                 = var.point_in_time_recovery
    recovery_period_in_days = var.point_in_time_recovery ? var.pitr_window_days : null
  }

  tags = { Name = "${local.name}-delegator-allow-list" }
}

resource "aws_dynamodb_table" "provider_info" {
  name                        = "${local.name}-delegator-provider-info"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "provider"
  deletion_protection_enabled = var.deletion_protection

  attribute {
    name = "provider"
    type = "S"
  }

  point_in_time_recovery {
    enabled                 = var.point_in_time_recovery
    recovery_period_in_days = var.point_in_time_recovery ? var.pitr_window_days : null
  }

  tags = { Name = "${local.name}-delegator-provider-info" }
}
