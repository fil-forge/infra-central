# Account-wide bootstrap for the prod account: the state bucket, the two roles
# GitHub Actions would assume to deploy the prod stage, and the break-glass role
# for the regional root's KMS keys.
#
# The non-prod copy of this directory carries the full explanation of why the
# bootstrap is split into an account root and a regional one, and why this half
# is the one applied by hand.
#
# Its first apply follows the greenfield procedure in the README, because the
# bucket its own backend names does not exist until that apply creates it.

provider "aws" {
  region = "us-east-2"

  allowed_account_ids = [module.constants.prod_account_id]
}

module "constants" {
  source = "../../../../modules/shared/constants"
}

module "tfstate" {
  source = "../../../../modules/tfstate"

  bucket_name = "forge-central-tfstate-${module.constants.prod_account_id}"
}

# The roles check-and-deploy.yml assumes for the prod plan and apply jobs.
module "github_actions_iam" {
  source = "../../../../modules/github-actions-iam"

  repository = "fil-forge/infra-central"

  # Read from the repository, not composed from its name: GitHub mints the
  # repo segment of the sub claim with owner and repository ids for a
  # repository created after 2026-07-15, and this one was. See the variable's
  # description for the command that prints it.
  repository_subject_prefix = "repo:fil-forge@280998881/infra-central@1331266425"
  account_id                = module.constants.prod_account_id
  state_bucket_name         = module.tfstate.bucket_name

  # From the one list the regional root also reads to create the stage's log
  # Firehose; see the constants module.
  state_key_prefixes = module.constants.prod_stages
}

# One Route53 zone per public service name. fil-forge.com is served by
# Cloudflare and prod's services sit directly beneath it (upload.fil-forge.com,
# not upload.prod.fil-forge.com), so no single delegated subzone covers them.
# fil-one/infrastructure delegates each name here with an NS record carrying the
# name servers this root outputs.
#
# Here rather than in the prod platform root because the zones must outlive it.
# The platform root is destroyed and re-applied when the first prod stack is
# reset, and a recreated zone gets new name servers, which would break every
# delegation until fil-one/infrastructure caught up. prevent_destroy makes that
# mistake fail at plan time.
#
# The suffix is prod's hostname_suffix from envs/prod/platform/terraform.tfvars,
# stated again here because a bootstrap root cannot read a stage's tfvars.
resource "aws_route53_zone" "service" {
  for_each = toset(values(module.constants.public_hostname_labels))

  name = "${each.key}.fil-forge.com"

  lifecycle {
    prevent_destroy = true
  }
}

# The role Site-to-Site VPN keeps each tunnel's pre-shared keys in Secrets
# Manager through, for the compatibility server's VPN in the platform root.
# AWS documents creating it on demand only for certificate-authenticated VPNs,
# and the platform root's VPN connections use pre-shared keys, so it is created
# here, once for the account, before the first connection. If it already
# exists, import it before applying:
#
#   tofu import aws_iam_service_linked_role.s2svpn \
#     arn:aws:iam::<prod account id>:role/aws-service-role/s2svpn.amazonaws.com/AWSServiceRoleForVPCS2SVPN
resource "aws_iam_service_linked_role" "s2svpn" {
  aws_service_name = "s2svpn.amazonaws.com"
}

# The break-glass role: the only principal, besides the account's root user,
# that the policies of the Aurora and OpenBao seal keys let schedule deletion
# of, disable, re-policy or re-alias them. See the regional root for the guard
# and docs/region-loss.md for when to use it.
#
# Only the people below may assume it, each from their own AdministratorAccess
# SSO session. Identity Center names a session after the user, so aws:userid
# ends in their username. The guard stops CI and mistakes, not an admin set on
# it: AdministratorAccess can rewrite this trust policy.
#
# AdministratorAccess, because an operator applies the whole regional root as
# this role whenever a key's policy or replica changes.
locals {
  kms_break_glass_users = [
    "alan@fil.org",
    "hannah@fil.org",
    "miroslav@fil.org",
  ]
}

data "aws_iam_policy_document" "kms_break_glass_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${module.constants.prod_account_id}:root"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:PrincipalArn"
      # Identity Center puts its roles under /aws-reserved/sso.amazonaws.com/,
      # with a region segment in some accounts and none in others.
      values = ["arn:aws:iam::${module.constants.prod_account_id}:role/aws-reserved/sso.amazonaws.com/*AWSReservedSSO_AdministratorAccess_*"]
    }

    condition {
      test     = "StringLike"
      variable = "aws:userid"
      values   = [for user in local.kms_break_glass_users : "*:${user}"]
    }
  }
}

resource "aws_iam_role" "kms_break_glass" {
  name                 = module.constants.prod_kms_break_glass_role_name
  description          = "Break-glass for the prod Aurora and OpenBao seal KMS keys. See docs/region-loss.md."
  assume_role_policy   = data.aws_iam_policy_document.kms_break_glass_assume.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "kms_break_glass" {
  role       = aws_iam_role.kms_break_glass.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

output "state_bucket_name" {
  value = module.tfstate.bucket_name
}

output "ci_plan_role_arn" {
  value = module.github_actions_iam.plan_role_arn
}

output "ci_apply_role_arn" {
  value = module.github_actions_iam.apply_role_arn
}

output "kms_break_glass_role_arn" {
  value = aws_iam_role.kms_break_glass.arn
}

# Paste these into the fil-one/infrastructure delegation, one NS record per
# zone, with proxied = false.
output "service_zone_name_servers" {
  value = { for name, zone in aws_route53_zone.service : zone.name => zone.name_servers }
}
