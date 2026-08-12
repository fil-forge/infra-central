# Bootstrap for the non-prod account in us-east-2: the ECR repositories every
# non-prod stage in this account and region pulls its images from.
#
# It lives in its own workspace because of a chicken-and-egg problem. The
# platform workspace requires an image digest, `make publish` cannot push
# without a repository, and Terraform cannot create the repository as part of
# the same apply that consumes the image.
#
# There is one of these directories per account and region, because an ECR
# repository serves only functions in the same account and region. Adding
# either means copying this directory and changing the workspace name, the
# region and the account guard. Nothing else in the tree is region-aware, so
# there is no shared list to keep in step.

terraform {
  required_version = ">= 1.15"

  cloud {
    organization = "Filecoin_Foundation"

    workspaces {
      name = "infra-central-bootstrap-nonprod-us-east-2"
    }
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "us-east-2"

  # A repository created in the wrong account is invisible until a stage's
  # Lambda fails to pull from it, so name the account the workspace belongs to
  # and let a mismatch fail at plan time instead.
  allowed_account_ids = [module.constants.nonprod_account_id]
}

module "constants" {
  source = "../../../../modules/constants"
}

module "ecr" {
  source = "../../../../modules/ecr"
}

output "provision_repository_url" {
  value = module.ecr.provision_repository_url
}
