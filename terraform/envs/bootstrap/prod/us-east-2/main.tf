# Regional bootstrap for the prod account in us-east-2: the ECR repositories the
# prod stage pulls its images from, and nothing else.
#
# The non-prod copy of this directory carries the full explanation of why the
# state bucket and the CI roles are not here but in ../account/.
#
# Nothing here has been applied yet: the prod account holds no
# forge-central/provision repository. It cannot be applied before ../account/,
# which creates the bucket this root's backend names.

provider "aws" {
  region = "us-east-2"

  allowed_account_ids = [module.constants.prod_account_id]
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
