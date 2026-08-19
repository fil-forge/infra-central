# The two roles GitHub Actions assumes to plan and apply this repository.
#
# Two, not one, because of how the `pull_request` event works: GitHub runs the
# workflow file from the pull request's own head, so whoever opens a pull request
# decides what commands run with the credentials the plan job holds. A single
# role scoped only by repository would hand that to anyone with push access. So
# the plan role can describe infrastructure and read nothing, and the role that
# can change anything is reachable only from `refs/heads/main`, which is a
# branch a pull request cannot write to.
#
# Nothing here stores an access key. The run exchanges its GitHub OIDC token for
# credentials that expire with it, the same arrangement HCP used and the reason
# no workspace ever held a secret.

# Read, never create. Both accounts already have this provider — it is one per
# account and shared with every other repository that deploys into them, so
# creating it here would fail with EntityAlreadyExists and adopting it into this
# state would let a destroy of this module break those other repositories.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

locals {
  # The `sub` claim GitHub puts in the token, which is what distinguishes a pull
  # request from a push to main. Matched with StringEquals rather than a
  # wildcard: `repo:<owner>/<repo>:*` would make the two roles interchangeable
  # and defeat the split above.
  #
  # Two accepted values per role, not one, because GitHub mints the repo segment
  # of that claim in either of two shapes. A repository created, renamed or
  # transferred after 2026-07-15 gets the immutable shape, which carries the
  # owner and repository ids: `repo:<owner>@<owner_id>/<repo>@<repo_id>`. Older
  # ones keep the plain `repo:<owner>/<repo>`. A trust policy naming only the
  # plain shape fails on a new repository with AWS's one opaque message for
  # every trust failure, "Not authorized to perform sts:AssumeRoleWithWebIdentity",
  # which says nothing about which condition did not match. Listing both means a
  # repository moving between the two shapes does not lock its own CI out.
  #
  # A values list is an OR, so this widens what each role accepts by exactly one
  # string and keeps the plan/apply split intact.
  plan_subjects = [
    "repo:${var.repository}:pull_request",
    "${var.repository_subject_prefix}:pull_request",
  ]
  apply_subjects = [
    "repo:${var.repository}:ref:refs/heads/main",
    "${var.repository_subject_prefix}:ref:refs/heads/main",
  ]

  state_bucket_arn = "arn:aws:s3:::${var.state_bucket_name}"
}

data "aws_iam_policy_document" "plan_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.plan_subjects
    }
  }
}

data "aws_iam_policy_document" "apply_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.apply_subjects
    }
  }
}

resource "aws_iam_role" "plan" {
  name               = "${var.name_prefix}-ci-plan"
  description        = "GitHub Actions: tofu plan on pull requests. Describes infrastructure, reads no data."
  assume_role_policy = data.aws_iam_policy_document.plan_assume.json
}

resource "aws_iam_role" "apply" {
  name               = "${var.name_prefix}-ci-apply"
  description        = "GitHub Actions: tofu apply on pushes to main."
  assume_role_policy = data.aws_iam_policy_document.apply_assume.json
}

resource "aws_iam_role_policy" "plan" {
  name   = "plan"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.plan.json
}

resource "aws_iam_role_policy" "apply" {
  name   = "apply"
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.apply.json
}
