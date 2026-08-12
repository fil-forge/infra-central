# Dev platform: VPC, RDS, S3, DynamoDB, ALB, OpenBao and the provision Lambda.
#
# Apply this before envs/dev/apps, which reads its outputs.

terraform {
  required_version = ">= 1.9"

  cloud {
    organization = "fil-forge"

    workspaces {
      name = "infra-central-dev-platform"
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

  default_tags {
    tags = {
      Project = "infra-central"
      Stage   = "dev"
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-2"
}

variable "zone_name" {
  description = "Route53 hosted zone this stage writes records into. fil.one is served by Cloudflare, so this must be the delegated subdomain that actually exists in Route53."
  type        = string
}

variable "hostname_suffix" {
  description = "Suffix every service hostname shares. Stated explicitly rather than derived from zone_name, because the delegation point and the hostname shape need not match: one forge.fil.one zone can serve dev.forge.fil.one and prod.forge.fil.one alike."
  type        = string
}

variable "chain" {
  description = "Chain and contract configuration, in terraform.tfvars. Owned here so the apps workspace can read it rather than keeping a second copy."
  type = object({
    rpc_url  = string
    chain_id = number
    contracts = object({
      fwss                      = string
      filecoin_pay              = string
      service_provider_registry = string
      usdfc_token               = string
    })
  })
}

variable "provision_image_repository_url" {
  description = "From the repository_url output of the bootstrap workspace for this stage's region."
  type        = string
}

# Written by `make publish` into the gitignored image.auto.tfvars, so the dev
# loop is `make publish && terraform apply` with nothing to edit by hand.
variable "provision_image_digest" {
  type = string
}

module "platform" {
  source = "../../../modules/platform"

  stage           = "dev"
  zone_name       = var.zone_name
  hostname_suffix = var.hostname_suffix

  provision_image_repository_url = var.provision_image_repository_url
  provision_image_digest         = var.provision_image_digest

  chain = var.chain

  # Dev runs small and single-AZ. The appliance availability argument that
  # justifies multi-AZ in prod does not apply to a stage with no appliances.
  db_instance_class        = "db.t4g.micro"
  db_multi_az              = false
  db_backup_retention_days = 1

  # Lets a dev stage actually be destroyed. Note that destroying it does not
  # remove the SSM parameters: the provision Lambda creates them, not
  # Terraform, so a recreated dev stage comes back with its previous DIDs.
  protect_stateful_resources = false

  # A db.t4g.micro allows roughly 112 connections. OpenBao takes 8 here, which
  # leaves headroom for sprue, hilt and swarf at 10 each.
  openbao_max_parallel = 8
}
