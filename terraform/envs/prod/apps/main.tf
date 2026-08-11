# Prod apps: the six ECS services.
#
# Reads the platform workspace's state rather than re-deriving anything, so a
# routine image bump plans in seconds and never touches the database.

terraform {
  required_version = ">= 1.9"

  cloud {
    organization = "fil-forge"

    workspaces {
      name = "infra-central-prod-apps"
    }
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    tfe = {
      source  = "hashicorp/tfe"
      version = "~> 0.58"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project = "infra-central"
      Stage   = "prod"
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-2"
}

variable "image_tags" {
  description = "Pinned per service in terraform.tfvars, so a deploy names exactly which build ships and arrives as a reviewable diff."
  type = object({
    sprue           = string
    hilt            = string
    swarf           = string
    delegator       = string
    signing_service = string
    plc             = string
  })

}

data "tfe_outputs" "platform" {
  organization = "fil-forge"
  workspace    = "infra-central-prod-platform"
}

locals {
  platform = data.tfe_outputs.platform.values.platform
}

module "apps" {
  source = "../../../modules/apps"

  stage           = local.platform.stage
  hostname_suffix = local.platform.hostname_suffix

  cluster_arn       = local.platform.cluster_arn
  vpc_id            = local.platform.vpc_id
  subnet_ids        = local.platform.private_subnet_ids
  security_group_id = local.platform.service_security_group_id
  kms_key_arn       = local.platform.kms_key_arn

  listener_arn    = local.platform.listener_arn
  route53_zone_id = local.platform.route53_zone_id
  alb_dns_name    = local.platform.alb_dns_name
  alb_zone_id     = local.platform.alb_zone_id

  namespace_id   = local.platform.namespace_id
  namespace_name = local.platform.namespace_name

  bucket_names             = local.platform.bucket_names
  bucket_arns              = local.platform.bucket_arns
  allow_list_table_name    = local.platform.allow_list_table_name
  provider_info_table_name = local.platform.provider_info_table_name
  dynamodb_table_arns      = local.platform.dynamodb_table_arns

  openbao_internal_address = local.platform.openbao_internal_address

  # Neither service is deployed yet. The delegator validates proofs signed by
  # these DIDs at startup, so the names have to be settled even though nothing
  # answers at them.
  indexer_did  = "did:web:indexer.${local.platform.hostname_suffix}"
  etracker_did = "did:web:etracker.${local.platform.hostname_suffix}"

  image_tags = var.image_tags

  # One home per stage: the platform workspace owns it, this one reads it.
  chain = local.platform.chain

  # Real money: storage is provisioned only against a funded payment plan.
  allow_provision_without_payment_plan = false

  log_level = "info"
}

output "service_urls" {
  value = module.apps.service_urls
}

output "service_dids" {
  value = module.apps.service_dids
}
