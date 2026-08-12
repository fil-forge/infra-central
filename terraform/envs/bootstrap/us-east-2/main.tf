# Bootstrap for us-east-2: the ECR repositories every stage in this region pulls
# its images from.
#
# It lives in its own workspace because of a chicken-and-egg problem. The
# platform workspace requires an image digest, `make publish` cannot push
# without a repository, and Terraform cannot create the repository as part of
# the same apply that consumes the image.
#
# Adding a region means copying this directory, changing the two region names,
# and running `make publish AWS_REGION=<region>`. Nothing else in the tree is
# region-aware, so there is no shared list to keep in step.

terraform {
  required_version = ">= 1.15"

  cloud {
    organization = "Filecoin_Foundation"

    workspaces {
      name = "infra-central-bootstrap-us-east-2"
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
}

module "ecr" {
  source = "../../../modules/ecr"
}

output "provision_repository_url" {
  value = module.ecr.provision_repository_url
}
