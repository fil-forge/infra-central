# Account-wide bootstrap for the prod account: the state bucket, and the two
# roles GitHub Actions would assume to deploy the prod stage.
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

output "state_bucket_name" {
  value = module.tfstate.bucket_name
}

output "ci_plan_role_arn" {
  value = module.github_actions_iam.plan_role_arn
}

output "ci_apply_role_arn" {
  value = module.github_actions_iam.apply_role_arn
}

# Paste these into the fil-one/infrastructure delegation, one NS record per
# zone, with proxied = false.
output "service_zone_name_servers" {
  value = { for name, zone in aws_route53_zone.service : zone.name => zone.name_servers }
}
