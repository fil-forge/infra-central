# Bootstrap for the prod account in us-east-2: the ECR repositories the prod
# stage in this region pulls its images from.
#
# The non-prod copy of this directory carries the full explanation of why the
# bootstrap is a workspace of its own and why there is one per account and
# region.

terraform {
  required_version = ">= 1.15"

  cloud {
    organization = "Filecoin_Foundation"

    workspaces {
      name = "forge-central-bootstrap-prod-us-east-2"
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
