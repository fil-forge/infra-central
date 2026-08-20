# Dev apps: the six ECS services.
#
# Reads the platform root's state rather than re-deriving anything, so a routine
# image bump plans in seconds and never touches the database. The `needs:` edge in
# .github/workflows/check-and-deploy.yml is what keeps the two in order: both are applied on
# every push to main, and this one has to wait for the outputs it reads.

provider "aws" {
  region = var.region

  # Credentials for another account would otherwise apply a second, quietly
  # working copy of the stage there. This fails the plan instead.
  allowed_account_ids = [module.constants.nonprod_account_id]

  default_tags {
    tags = {
      Project = "forge-central"
      Stage   = "dev"
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

variable "image_digests" {
  description = "Pinned per service in terraform.tfvars. Dev pins digests like prod: HCP applies this workspace on every commit to main, and a rolling tag would make what dev runs depend on when a task last restarted rather than on what was merged."
  type = object({
    sprue           = string
    hilt            = string
    swarf           = string
    delegator       = string
    signing_service = string
    plc             = string
  })
}

# The platform root's state, read straight from the bucket. Bucket and key are
# stated literally so they read the same as the backend block in
# envs/dev/platform/versions.tofu, which cannot take a variable. Two literals
# that have to match are easier to check than one literal and one expression.
data "terraform_remote_state" "platform" {
  backend = "s3"

  config = {
    bucket = "forge-central-tfstate-654654381893"
    key    = "dev/platform.tfstate"
    region = "us-east-2"
  }
}

locals {
  platform = data.terraform_remote_state.platform.outputs.platform
}

module "apps" {
  source = "../../../modules/apps"

  stage           = local.platform.stage
  hostname_suffix = local.platform.hostname_suffix

  cluster_arn       = local.platform.cluster_arn
  vpc_id            = local.platform.vpc_id
  subnet_ids        = local.platform.private_subnet_ids
  security_group_id = local.platform.service_security_group_id

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

  image_digests = var.image_digests

  # One home per stage: the platform workspace owns it, this one reads it.
  chain = local.platform.chain

  # Matches smelt's staging, where uploads are exercised without a funded plan.
  allow_provision_without_payment_plan = true

  log_level = "info"
}

output "service_urls" {
  value = module.apps.service_urls
}

output "service_dids" {
  value = module.apps.service_dids
}
