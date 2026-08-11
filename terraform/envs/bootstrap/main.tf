# The one thing that must exist before any stage can be applied: the ECR
# repository holding the forge-provision Lambda image.
#
# It lives in its own workspace because of a chicken-and-egg problem. The
# platform workspace requires an image digest, `make publish` cannot push
# without a repository, and Terraform cannot create the repository as part of
# the same apply that consumes the image.
#
# Applied once per account *and region*, not once per account and not per stage.
# ECR repositories are regional, and Lambda will only pull an image from ECR in
# the same region as the function, so a stage in another region cannot reuse
# this repository. Standing up a second region means a second workspace with a
# region-qualified name, e.g. forge-central-bootstrap-us-west-2, and a
# `make publish AWS_REGION=us-west-2` to fill it.
#
# Stages sharing a region share this repository. They pin different digests, so
# they do not interfere.

terraform {
  required_version = ">= 1.9"

  cloud {
    organization = "fil-forge"

    workspaces {
      name = "forge-central-bootstrap"
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
  region = var.region
}

variable "region" {
  type    = string
  default = "us-east-2"
}

resource "aws_ecr_repository" "provision" {
  name                 = "forge-provision"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

# Untagged images accumulate quickly when iterating: every `make publish` from
# a dev box replaces the sha- tag and orphans the previous manifest.
resource "aws_ecr_lifecycle_policy" "provision" {
  repository = aws_ecr_repository.provision.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images after 14 days"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 14
      }
      action = { type = "expire" }
    }]
  })
}

output "repository_url" {
  description = "Pass to each stage as provision_image_repository_url."
  value       = aws_ecr_repository.provision.repository_url
}
