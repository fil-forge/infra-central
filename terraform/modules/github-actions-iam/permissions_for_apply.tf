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
  # No ecr:BatchGetImage either, and no ecr:SetRepositoryPolicy. Lambda pulls
  # the provision image under the repository policy the bootstrap root sets;
  # the apply only pins a digest.

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

  # Bucket-level administration of the stage's own buckets. Sprue writes the
  # objects in them, and an apply has no business reading an agent message or a
  # delegation, so no action here takes an object ARN.
  #
  # The list is enumerated because `*` in a resource ARN also matches `/`:
  # `s3:*` on `arn:aws:s3:::fc-*` covers every key in every stage bucket. The
  # reads are the plan role's, which is what refreshing a bucket needs. The
  # writes are what the aws_s3_bucket_* resources in the terraform/ tree call.
  # CreateBucket sends the bucket's tags inline, which AWS authorises as
  # s3:TagResource.
  #
  # Two indirect paths to the objects remain. PutBucketPolicy, which the ALB
  # log bucket's policy needs, could grant this role object access from the
  # bucket's side. And WriteStageRoles lets it create an fc-* role with any
  # policy and hand it to a Lambda it can invoke. Both belong to the wider
  # narrowing of this role tracked in FIL-1156.
  statement {
    sid       = "ManageStageBuckets"
    resources = ["arn:aws:s3:::fc-*"]

    actions = [
      "s3:CreateBucket",
      "s3:DeleteBucket",
      "s3:DeleteBucketPolicy",
      "s3:GetAccelerateConfiguration",
      "s3:GetBucket*",
      "s3:GetEncryptionConfiguration",
      "s3:GetLifecycleConfiguration",
      "s3:GetReplicationConfiguration",
      "s3:ListBucket",
      "s3:ListBucketVersions",
      "s3:PutBucketPolicy",
      "s3:PutBucketPublicAccessBlock",
      "s3:PutBucketTagging",
      "s3:PutBucketVersioning",
      "s3:PutEncryptionConfiguration",
      "s3:PutLifecycleConfiguration",
      "s3:TagResource",
    ]
  }

  # Destroying a bucket with force_destroy set first empties it: the provider
  # lists every object version (ListBucketVersions, above) and deletes them in
  # bulk. Without these two actions a stage that is allowed to be destroyed
  # fails on its first non-empty bucket. Listing versions returns keys and
  # version IDs, and deleting needs no read, so the role can remove an object
  # but never read or overwrite its contents.
  dynamic "statement" {
    for_each = var.allow_emptying_stage_buckets ? [1] : []

    content {
      sid       = "EmptyStageBuckets"
      resources = ["arn:aws:s3:::fc-*/*"]

      actions = [
        "s3:DeleteObject",
        "s3:DeleteObjectVersion",
      ]
    }
  }

  # The appliance backup bucket, one per stage. The wildcard matches the
  # bucket's object ARNs too, so the action list is what withholds object
  # access: every action here works on the bucket and none reads or writes an
  # object. Adding s3:GetObject or s3:* would give every apply direct read
  # access to every appliance's database backups. The role can still reach them
  # indirectly, through the bucket policy or an fc-* role it writes, and review
  # of the merged change is the control there.
  statement {
    sid       = "ManageApplianceBackupBucket"
    resources = ["arn:aws:s3:::forge-nodes-backups-*"]

    actions = [
      "s3:CreateBucket",
      "s3:DeleteBucket",
      "s3:DeleteBucketPolicy",
      "s3:GetAccelerateConfiguration",
      "s3:GetBucket*",
      "s3:GetEncryptionConfiguration",
      "s3:GetLifecycleConfiguration",
      "s3:GetReplicationConfiguration",
      "s3:ListBucket",
      "s3:PutBucket*",
      "s3:PutEncryptionConfiguration",
      "s3:PutLifecycleConfiguration",
    ]
  }

  # Each region's backup writer. CI creates and deletes the users and their
  # inline policy, and never mints a key: the provision Lambda does that, so the
  # secret stays out of state. The deletes are what the AWS provider's
  # force_destroy calls when a retired region's user goes. DeleteLoginProfile
  # runs on every delete, and the others run when the user holds that kind of
  # credential, which in practice is the access key the Lambda minted.
  statement {
    sid       = "WriteApplianceBackupUsers"
    resources = ["arn:aws:iam::${var.account_id}:user/forge-nodes-backup-*"]

    actions = [
      "iam:CreateUser",
      "iam:DeactivateMFADevice",
      "iam:DeleteAccessKey",
      "iam:DeleteLoginProfile",
      "iam:DeleteServiceSpecificCredential",
      "iam:DeleteSigningCertificate",
      "iam:DeleteSSHPublicKey",
      "iam:DeleteUser",
      "iam:DeleteUserPolicy",
      "iam:DetachUserPolicy",
      "iam:PutUserPolicy",
      "iam:TagUser",
      "iam:UntagUser",
    ]
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

  # CreateDBInstance calls both of these itself when manage_master_user_password
  # is set, to create and tag the master password's own secret. Nothing else
  # here ever created a DB instance under this role: the stage's original one
  # was never destroyed and recreated, so the gap went unnoticed until a reset
  # did both for the first time. No DeleteSecret: RDS deletes the secret itself
  # on instance deletion without needing this role to hold that action.
  statement {
    sid       = "ManageStageMasterPasswordSecret"
    resources = ["*"]

    actions = [
      "secretsmanager:CreateSecret",
      "secretsmanager:TagResource",
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
