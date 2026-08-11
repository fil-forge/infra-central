# Prod platform.
#
# Differs from dev in three ways that matter: the database is multi-AZ and
# protected from deletion, OpenBao gets a larger connection budget, and the
# provision image is pinned by a committed digest rather than read from a
# developer's local file.

terraform {
  required_version = ">= 1.9"

  cloud {
    organization = "fil-forge"

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

  default_tags {
    tags = {
      Project = "forge-central"
      Stage   = "prod"
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
  type = string
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

  provision_image_repository_url = var.provision_image_repository_url
  provision_image_digest         = var.provision_image_digest

  chain = var.chain

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
}
