# What `tofu apply` needs. Scoped by service and, where an action is genuinely
# dangerous, by action.
#
# Everything the plan role holds, plus the three groups an apply needs and a
# refresh does not: iam:PassRole, for the task and execution roles the ECS
# services run as; lambda:InvokeFunction, because aws_lambda_invocation is what
# runs the provision Lambda's vault and seed phases; and the KMS grant actions
# RDS and ECS need to use a customer-managed key.
#
# This starts deliberately narrower than the AdministratorAccess the account's
# two existing CI roles carry, which means the first applies may fail on a
# missing action. When one does, the error names the action — add it here rather
# than reaching for the managed policy.
#
# IAM is enumerated rather than wildcarded, and its write actions are confined to
# the role names this project creates. A role that can write any IAM role can
# grant itself anything, so `iam:*` would make every other limit here decorative.
data "aws_iam_policy_document" "apply" {
  statement {
    sid       = "ManageStageInfrastructure"
    resources = ["*"]

    actions = [
      "acm:*",
      "application-autoscaling:*",
      "dynamodb:CreateTable",
      "dynamodb:DeleteTable",
      "dynamodb:Describe*",
      "dynamodb:List*",
      "dynamodb:TagResource",
      "dynamodb:UntagResource",
      "dynamodb:UpdateContinuousBackups",
      "dynamodb:UpdateTable",
      "dynamodb:UpdateTimeToLive",
      "ec2:*",
      "ecr:Describe*",
      "ecr:GetAuthorizationToken",
      "ecr:GetRepositoryPolicy",
      "ecr:List*",
      "ecs:*",
      "elasticloadbalancing:*",
      "globalaccelerator:*",
      "lambda:*",
      "logs:*",
      "rds:*",
      "route53:*",
      "servicediscovery:*",
      "sts:GetCallerIdentity",
    ]
  }

  # No dynamodb:GetItem, Query, Scan, PutItem or DeleteItem: Terraform creates
  # the delegator's two tables but never touches a row in them, and an apply that
  # could read the allow list could read every tenant in the region.
  #
  # No ecr:BatchGetImage either. The Lambda pulls its own image with its own
  # execution role; the apply only pins a digest.

  statement {
    sid       = "ManageStageRoles"
    resources = ["*"]

    actions = [
      "iam:Get*",
      "iam:List*",
      "iam:CreateServiceLinkedRole",
    ]
  }

  statement {
    sid = "WriteStageRoles"

    actions = [
      "iam:AttachRolePolicy",
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PassRole",
      "iam:PutRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:UpdateRole",
    ]

    # Every role this project creates is named for its stage. The CI roles
    # themselves are forge-central-ci-*, created by the bootstrap from a laptop
    # and deliberately outside this pattern: a role that can rewrite its own
    # trust policy is not limited by it.
    resources = [
      "arn:aws:iam::${var.account_id}:role/fc-*",
      "arn:aws:iam::${var.account_id}:role/aws-service-role/*",
    ]
  }

  # Bucket-level administration of the stage's own buckets, and no object access
  # to them at all: sprue writes those objects, and an apply has no business
  # reading an upload shard or a delegation.
  statement {
    sid       = "ManageStageBuckets"
    actions   = ["s3:*"]
    resources = ["arn:aws:s3:::fc-*"]
  }

  statement {
    sid       = "ListBuckets"
    actions   = ["s3:ListAllMyBuckets"]
    resources = ["*"]
  }

  # kms:Decrypt and CreateGrant are here because RDS and ECS use the stage key
  # on the apply's behalf, not because the apply reads anything with it.
  statement {
    sid       = "ManageStageKey"
    resources = ["*"]

    actions = [
      "kms:CreateAlias",
      "kms:CreateGrant",
      "kms:CreateKey",
      "kms:Decrypt",
      "kms:DeleteAlias",
      "kms:DescribeKey",
      "kms:EnableKeyRotation",
      "kms:GenerateDataKey",
      "kms:GetKeyPolicy",
      "kms:GetKeyRotationStatus",
      "kms:ListAliases",
      "kms:ListResourceTags",
      "kms:PutKeyPolicy",
      "kms:ScheduleKeyDeletion",
      "kms:TagResource",
      "kms:UntagResource",
    ]
  }

  statement {
    sid = "ReadWriteState"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]

    resources = [for prefix in var.state_key_prefixes : "${local.state_bucket_arn}/${prefix}/*"]
  }

  statement {
    sid       = "ListStateBucket"
    actions   = ["s3:ListBucket"]
    resources = [local.state_bucket_arn]
  }
}
