# Account-wide bootstrap for the non-prod account: the state bucket every other
# root in this account keeps its state in, and the two roles GitHub Actions
# assumes to deploy the stages.
#
# Both are account-scoped rather than regional. An S3 bucket name is global, and
# IAM is not regional at all, so a second region creating these again would
# collide with what this root already owns. Hence the split: the regional half of
# the bootstrap is next door in <region>/ and holds one ECR repository, which is
# the only thing here a second region genuinely needs its own copy of.
#
# It lives in its own root because of a chicken-and-egg problem, twice over. The
# state bucket is what every other root's backend points at, so it cannot be
# created by an apply that already keeps its state there. And the CI roles cannot
# be created by the CI they authorise. So this root is applied by hand, once per
# account, and everything downstream of it is ordinary.

provider "aws" {
  # Where the state bucket lives. A bucket is a regional resource even though its
  # name is global, and the roles below are not regional at all, so this is the
  # account's home region rather than a region this project deploys into. A copy
  # of the sibling <region>/ directory leaves this alone.
  region = "us-east-2"

  # A bucket or a role created in the wrong account is invisible until another
  # root fails to reach it, so name the account this root belongs to and let a
  # mismatch fail at plan time instead.
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

  # Every non-prod stage the workflow deploys, from the one list the regional
  # root also reads. A stage added to .github/workflows/check-and-deploy.yml has
  # to be added to the constants module too, or its first run fails reading
  # state.
  #
  # Plus grafana, which is not a stage. terraform/envs/grafana holds the Forge
  # dashboards and alert rules; it describes every stage at once through a
  # $stage template variable, so it belongs to none of them, and its state key
  # carries no stage either. The apply-grafana job in the workflow cannot reach
  # grafana/forge.tfstate without this, and fails at `tofu init` with an access
  # denial on every push to main.
  #
  # Appended here rather than added to nonprod_stages, because that output is
  # also what the regional root hands modules/telemetry as its `stages`, one log
  # Firehose per entry. A "grafana" stage there would build a Firehose for a
  # stage that does not exist.
  #
  # Bootstrap state stays excluded, as the variable's description says: these
  # roots are applied by an operator from a laptop and no CI role needs them.
  state_key_prefixes = concat(module.constants.nonprod_stages, ["grafana"])
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
