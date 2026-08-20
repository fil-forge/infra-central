# What `tofu plan` needs, and nothing more.
#
# A refresh describes each resource in state; it never reads what a resource
# holds. The inventory is closed and small — the terraform/ tree manages 42
# resource types and reads 6 data sources, and none of them is an SSM parameter
# or a Secrets Manager secret, because the provision Lambda mints every secret
# at runtime rather than passing it through Terraform. So this list can be
# written out rather than approximated with a managed policy.
#
# AWS's ReadOnlyAccess would have been one line, and is what the two CI roles
# already in this account use. It also carries s3:GetObject on every bucket in
# the account, which combined with a pull request choosing what the plan job runs
# is an exfiltration path for application data, not just metadata. Hence the
# list, and hence what is missing from it: no s3:GetObject, no ssm:*, no
# secretsmanager:*, no kms:Decrypt, no dynamodb:GetItem, Query or Scan, no
# ecr:BatchGetImage, no lambda:InvokeFunction.
#
# The scoping here is by action, not by resource: creating a VPC or a subnet
# cannot be expressed against a resource ARN that does not exist yet, and several
# IAM and EC2 list actions reject a resource qualifier outright. An action that
# reads no data is safe against "*"; that is the property this list maintains.
#
# lambda:Get* is where action scoping alone does not hold it. GetFunction returns
# a presigned URL for the function's deployment package, so against "*" it lets a
# pull request download the code of every Lambda in the account. It gets its own
# statement below, scoped to the functions this project manages.
data "aws_iam_policy_document" "plan" {
  statement {
    sid       = "DescribeInfrastructure"
    resources = ["*"]

    actions = [
      "acm:Describe*",
      "acm:List*",
      "application-autoscaling:Describe*",
      "dynamodb:DescribeContinuousBackups",
      "dynamodb:DescribeTable",
      "dynamodb:DescribeTimeToLive",
      "dynamodb:ListTagsOfResource",
      "ec2:Describe*",
      "ecr:Describe*",
      "ecr:GetRepositoryPolicy",
      "ecr:ListTagsForResource",
      "ecs:Describe*",
      "ecs:List*",
      "elasticloadbalancing:Describe*",
      "globalaccelerator:Describe*",
      "globalaccelerator:List*",
      "iam:Get*",
      "iam:List*",
      "kms:DescribeKey",
      "kms:GetKeyPolicy",
      "kms:GetKeyRotationStatus",
      "kms:ListAliases",
      "kms:ListResourceTags",
      # lambda:Get* is not here; see DescribeStageFunctions below. The list
      # actions are, because ListFunctions rejects a resource qualifier and the
      # configuration it returns carries no code URL.
      "lambda:List*",
      "logs:Describe*",
      "logs:ListTagsForResource",
      "rds:Describe*",
      "rds:ListTagsForResource",
      "route53:Get*",
      "route53:List*",
      # GetBucket* misses two of the calls refreshing an aws_s3_bucket makes:
      # GetAccelerateConfiguration and GetReplicationConfiguration are not named
      # for the bucket. All five read bucket configuration, never an object.
      "s3:GetAccelerateConfiguration",
      "s3:GetBucket*",
      "s3:GetEncryptionConfiguration",
      "s3:GetLifecycleConfiguration",
      "s3:GetReplicationConfiguration",
      "s3:ListAllMyBuckets",
      "s3:ListBucket",
      "servicediscovery:Get*",
      "servicediscovery:List*",
      "sts:GetCallerIdentity",
    ]
  }

  # Every function this project creates is named for its stage, and the prefix is
  # what keeps that presigned code URL to images this repository builds.
  #
  # The region is a wildcard because these roles are account-scoped: one pair
  # covers every region a stage is deployed into.
  statement {
    sid       = "DescribeStageFunctions"
    actions   = ["lambda:Get*"]
    resources = ["arn:aws:lambda:*:${var.account_id}:function:fc-*"]
  }

  # A plan reads state and takes a lock, and use_lockfile keeps the lock in a
  # separate <key>.tflock object. That is what lets the plan role write the lock
  # without being able to write the state file it locks: a pull request that
  # could PutObject over dev/platform.tfstate could replace the record of a live
  # stage.
  statement {
    sid       = "ReadState"
    actions   = ["s3:GetObject"]
    resources = [for prefix in var.state_key_prefixes : "${local.state_bucket_arn}/${prefix}/*.tfstate"]
  }

  statement {
    sid = "HoldStateLock"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]

    resources = [for prefix in var.state_key_prefixes : "${local.state_bucket_arn}/${prefix}/*.tflock"]
  }

  # Unprefixed, because `tofu init` lists the bucket before it knows its own key.
  # It lets this role enumerate the other key names in the account's bucket, which
  # are a stage name and `bootstrap/` — names, not contents, and both are in this
  # repository already.
  statement {
    sid       = "ListStateBucket"
    actions   = ["s3:ListBucket"]
    resources = [local.state_bucket_arn]
  }
}
