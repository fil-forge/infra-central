# Bootstrap for the non-prod account in us-east-2: the state bucket every other
# root here keeps its state in, the ECR repositories every non-prod stage pulls
# its images from, and the two roles GitHub Actions assumes to deploy them.
#
# It lives in its own root because of a chicken-and-egg problem, three times
# over. The platform root requires an image digest, `make publish` cannot push
# without a repository, and Terraform cannot create the repository as part of the
# same apply that consumes the image. The state bucket is worse: it is what every
# other root's backend points at. And the CI roles cannot be created by the CI
# they authorise. So this one root is applied by hand, and everything else is
# applied by a workflow.
#
# There is one of these directories per account and region, because an ECR
# repository serves only functions in the same account and region. Adding either
# means copying this directory and changing the state key, the region and the
# account guard. Nothing else in the tree is region-aware, so there is no shared
# list to keep in step.

provider "aws" {
  region = "us-east-2"

  # A repository created in the wrong account is invisible until a stage's
  # Lambda fails to pull from it, so name the account this root belongs to and
  # let a mismatch fail at plan time instead.
  allowed_account_ids = [module.constants.nonprod_account_id]
}

module "constants" {
  source = "../../../../modules/shared/constants"
}

module "tfstate" {
  source = "../../../../modules/tfstate"

  # Hard-coded in every backend block in this account, so it cannot be derived
  # from the constants module the way an image URL is. Stated here in the same
  # shape those blocks state it, and guarded by allowed_account_ids above.
  bucket_name = "forge-central-tfstate-${module.constants.nonprod_account_id}"
}

module "ecr" {
  source = "../../../../modules/ecr"
}

module "github_actions_iam" {
  source = "../../../../modules/github-actions-iam"

  repository = "fil-forge/infra-central"

  # Read from the repository, not composed from its name: GitHub mints the
  # repo segment of the sub claim with owner and repository ids for a
  # repository created after 2026-07-15, and this one was. See the variable's
  # description for the command that prints it.
  repository_subject_prefix = "repo:fil-forge@280998881/infra-central@1331266425"
  account_id                = module.constants.nonprod_account_id
  state_bucket_name         = module.tfstate.bucket_name

  # Every non-prod stage the workflow deploys. A stage added to
  # .github/workflows/check-and-deploy.yml has to be added here too, or its first run
  # fails reading state.
  state_key_prefixes = ["dev"]
}

output "provision_repository_url" {
  value = module.ecr.provision_repository_url
}

output "state_bucket_name" {
  value = module.tfstate.bucket_name
}

# Paste these into .github/workflows/check-and-deploy.yml. They are derived from the
# account id and the role names, so they change only if this root is renamed.
output "ci_plan_role_arn" {
  value = module.github_actions_iam.plan_role_arn
}

output "ci_apply_role_arn" {
  value = module.github_actions_iam.apply_role_arn
}
