# Bootstrap for us-east-2: the ECR repository every stage in this region pulls
# the forge-provision Lambda image from.
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
    organization = "fil-forge"

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

module "provision_ecr" {
  source = "../../../modules/provision-ecr"
}

output "repository_url" {
  value = module.provision_ecr.repository_url
}
