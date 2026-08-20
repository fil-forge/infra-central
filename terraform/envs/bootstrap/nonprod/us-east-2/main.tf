# Regional bootstrap for the non-prod account in us-east-2: the ECR repositories
# every non-prod stage in this region pulls its images from.
#
# One of these directories per account and region, because an ECR repository
# serves only functions in the same account and region. It holds nothing else.
# The account-wide half of the bootstrap — the state bucket and the CI roles — is
# in ../account/, and is deliberately not here: an S3 bucket name is global and
# IAM is not regional, so a copy of this directory for a second region would
# collide with the first on both.
#
# It is applied by hand rather than by CI, like the account root next door,
# because the image it makes room for is pushed by hand too: the platform root
# requires a digest, `make publish` cannot push without a repository, and
# Terraform cannot create the repository as part of the same apply that consumes
# the image.
#
# Adding a region means copying this directory and changing two things, the
# provider region below and the backend key in versions.tofu. Nothing else in the
# tree is region-aware, so there is no shared list to keep in step.

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

module "ecr" {
  source = "../../../../modules/ecr"
}

output "provision_repository_url" {
  value = module.ecr.provision_repository_url
}
