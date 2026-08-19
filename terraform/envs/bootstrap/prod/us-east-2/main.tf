# Bootstrap for the prod account in us-east-2: the state bucket, the ECR
# repositories the prod stage pulls its images from, and the two roles GitHub
# Actions would assume to deploy it.
#
# The non-prod copy of this directory carries the full explanation of why the
# bootstrap is a root of its own, why there is one per account and region, and
# why it is the one thing applied by hand.
#
# Nothing here has been applied yet: the prod account holds no
# forge-central/provision repository. Its first apply follows the greenfield
# procedure in the README, because the bucket its own backend names does not
# exist yet either.

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

module "ecr" {
  source = "../../../../modules/ecr"
}

# Created now so prod needs no second bootstrap apply when it is stood up, and
# so the trust policies are reviewed once rather than under deadline. No workflow
# names these roles yet: check-and-deploy.yml covers dev only, because prod's tfvars still
# carry REPLACE_ME contract addresses and no image digests.
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

  state_key_prefixes = ["prod"]
}

output "provision_repository_url" {
  value = module.ecr.provision_repository_url
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
