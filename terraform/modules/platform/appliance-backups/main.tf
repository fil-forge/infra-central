# Where regional appliances push their Postgres WAL and base backups and their
# OpenBao raft snapshots: one bucket per stage, one writer user per region.
#
# The bucket is locked in compliance mode, so no credential, an administrator's
# included, can delete or overwrite a backup until its retention ends. Each
# region's user can add objects under its own prefix and read nothing but the
# Postgres timeline history files WAL-G checks before it uploads one. Why it is
# shaped this way is in docs/decisions/2026-11-appliance-backup-target.md.
#
# The access keys are not created here. The provision Lambda's
# appliance-backup-key phase mints them, so no secret enters Terraform state.

locals {
  bucket_name = "forge-nodes-backups-${var.stage}-${var.account_id}"
  user_prefix = "forge-nodes-backup-${var.stage}-"
}

# A compliance-locked object cannot be deleted before its retention ends, so
# neither can the bucket holding it. prevent_destroy rejects a plan that would
# try, here and on the three resources below whose removal would change what
# is kept and for how long.
resource "aws_s3_bucket" "this" {
  bucket              = local.bucket_name
  object_lock_enabled = true

  tags = { Name = local.bucket_name }

  lifecycle {
    prevent_destroy = true

    precondition {
      condition     = length(local.bucket_name) <= 63
      error_message = "The bucket name ${local.bucket_name} is ${length(local.bucket_name)} characters; S3 allows 63."
    }
  }
}

# Object Lock requires versioning, and S3 turns it on with the lock. Declaring it
# keeps Terraform's view the same as the bucket's.
resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = "Enabled"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_object_lock_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    default_retention {
      mode = "COMPLIANCE"
      days = var.retention_days
    }
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [aws_s3_bucket_versioning.this]
}

# SSE-S3 rather than a KMS key. A multipart upload under SSE-KMS needs
# kms:Decrypt on the uploader, which would hand every appliance the key that
# was meant to gate reads.
resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# An object's current version gets a delete marker once its retention ends, and
# the version behind it is deleted a day later, after its lock has lapsed. A
# backup is therefore gone 36 days after it was written. A put to an existing
# key leaves the earlier version locked and noncurrent, and it goes the day
# after its own retention ends.
resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    id     = "expire-backups"
    status = "Enabled"

    filter {}

    expiration {
      days = var.retention_days
    }
  }

  rule {
    id     = "delete-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 1
    }
  }

  # Its own rule, because S3 refuses expired_object_delete_marker beside days.
  # Without it a key whose versions have all gone keeps its delete marker, and
  # the marker is listed forever.
  rule {
    id     = "remove-expired-delete-markers"
    status = "Enabled"

    filter {}

    expiration {
      expired_object_delete_marker = true
    }
  }

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [aws_s3_bucket_versioning.this]
}

data "aws_iam_policy_document" "bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.this.arn, "${aws_s3_bucket.this.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = data.aws_iam_policy_document.bucket.json

  # S3 rejects a policy write while the public access block is being applied.
  depends_on = [aws_s3_bucket_public_access_block.this]
}

# One writer per region. Moving a label to retired_appliance_regions removes it
# from var.regions, so the next apply deletes the user and, through
# force_destroy, the access key the provision Lambda minted for it. The node's
# uploads stop within seconds; the backups it already wrote expire on schedule.
resource "aws_iam_user" "writer" {
  for_each = toset(var.regions)

  name          = "${local.user_prefix}${each.key}"
  force_destroy = true

  tags = { Region = each.key }

  lifecycle {
    precondition {
      condition     = length("${local.user_prefix}${each.key}") <= 64
      error_message = "The user name ${local.user_prefix}${each.key} is ${length("${local.user_prefix}${each.key}")} characters; IAM allows 64. Shorten the region label."
    }

    # scripts/restore-appliance-backups.sh copies under restores/, which only an
    # administrator may write. A region of that name would write there too.
    precondition {
      condition     = each.key != "restores"
      error_message = "The region label restores is reserved: restores/ holds the copies a post-leak restore reads."
    }
  }
}

data "aws_iam_policy_document" "writer" {
  for_each = toset(var.regions)

  # PutObject covers every step of a multipart upload. No DeleteObject: a writer
  # that cannot delete cannot leave a delete marker in front of a backup either.
  statement {
    sid       = "WriteOwnBackups"
    actions   = ["s3:PutObject", "s3:AbortMultipartUpload"]
    resources = ["${aws_s3_bucket.this.arn}/${each.key}/*"]
  }

  # WAL-G reads a timeline history file back before uploading one under the same
  # name, and refuses to overwrite it if the content differs. These files carry
  # timeline switch points and no table data.
  statement {
    sid       = "ReadOwnTimelineHistory"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.this.arn}/${each.key}/postgres/*.history*"]
  }

  # Lets the read above answer 404 for a history file that does not exist yet,
  # where without ListBucket S3 answers 403 and WAL-G fails. The prefix keeps
  # each appliance from listing the key names of every other region's backups.
  statement {
    sid       = "ListOwnPrefix"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.this.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${each.key}/*"]
    }
  }
}

resource "aws_iam_user_policy" "writer" {
  for_each = aws_iam_user.writer

  name   = "write-backups"
  user   = each.value.name
  policy = data.aws_iam_policy_document.writer[each.key].json
}
