# Prod platform.
#
# Differs from dev in three ways that matter: the database is multi-AZ and
# protected from deletion, OpenBao gets a larger connection budget, and the
# provision image digest is pinned in terraform.tfvars, copied from dev when a
# change is promoted rather than written by whatever was built last.
#
# The workspace does not exist yet. It will apply nothing without an operator
# confirming the plan, unlike dev.

terraform {
  required_version = ">= 1.15"

  cloud {
    organization = "Filecoin_Foundation"

    workspaces {
      name = "forge-central-prod-platform"
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

  # Credentials for another account would otherwise apply a second, quietly
  # working copy of the stage there. This fails the plan instead.
  allowed_account_ids = [module.constants.prod_account_id]

  default_tags {
    tags = {
      Project = "forge-central"
      Stage   = "prod"
    }
  }
}

module "constants" {
  source = "../../../modules/shared/constants"
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

variable "provision_image_digest" {
  description = "Pinned in terraform.tfvars. `make publish` prints the line to paste."
  type        = string
}

module "platform" {
  source = "../../../modules/platform"

  stage           = "prod"
  zone_name       = var.zone_name
  hostname_suffix = var.hostname_suffix

  # The repository the bootstrap workspace for this account and region created.
  # Derived rather than copied from its output: a Lambda can pull only from its
  # own account and region, so those two values are the whole address.
  provision_image_repository_url = "${module.constants.prod_account_id}.dkr.ecr.${var.region}.amazonaws.com/${module.constants.provision_repository_name}"
  provision_image_digest         = var.provision_image_digest

  chain = var.chain

  # Three availability zones with a NAT gateway in each, where dev accepts two
  # and a single shared gateway. Appliances depend on this stage being
  # reachable, so losing a zone must not cost it egress.
  #
  # az_count is fixed when the stage is created. Changing it later renumbers
  # the private subnets and replaces the database along with them; see the
  # network module's variable description before touching it.
  az_count           = 3
  nat_gateway_per_az = true

  db_instance_class        = "db.t4g.small"
  db_allocated_storage     = 50
  db_multi_az              = true
  db_backup_retention_days = 30

  # Regional appliances cannot boot while OpenBao is unreachable, and OpenBao's
  # storage is this database.
  protect_stateful_resources = true

  # A db.t4g.small allows roughly 225 connections, so 24 for OpenBao still
  # leaves ample room for the application services.
  openbao_max_parallel = 24

  container_insights = true

  # Two static addresses an appliance operator can allowlist once, and an edge
  # that takes a flood before the load balancer does. Dev has neither need.
  enable_global_accelerator = true
}
