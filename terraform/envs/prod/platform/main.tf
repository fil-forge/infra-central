# Prod platform.
#
# Differs from dev in the ways that matter: the database is an Aurora cluster
# with a writer and a reader, protected from deletion, OpenBao gets a larger
# connection budget, every public hostname is a Route53 zone of its own, and the
# provision image digest is pinned in terraform.tfvars, published to this
# account's repository by hand.
#
# .github/workflows/check-and-deploy.yml applies this root on every push to main,
# the same as staging. The first stack in this account is disposable; see
# docs/decisions/2026-10-prod-first-stack.md.

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

variable "hostname_suffix" {
  description = "Suffix every central service hostname shares. Stated explicitly because the hosted-zone delegation and hostname shape need not match."
  type        = string
}

variable "ingot_hostname_suffix" {
  description = "Suffix for region-qualified Ingot identities."
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

variable "appliance_regions" {
  description = "Region labels of the appliances this stage serves, in terraform.tfvars. See docs/appliance-onboarding.md."
  type        = list(string)
  default     = []
}

variable "retired_appliance_regions" {
  description = "Region labels whose appliance has been retired, in terraform.tfvars. Labels stay here for good: the apply refuses a key that neither list names."
  type        = list(string)
  default     = []
}

# Created by the regional bootstrap, which outlives this root.
data "aws_kms_alias" "aurora" {
  name = module.constants.prod_aurora_key_alias
}

data "aws_kms_alias" "openbao_seal" {
  name = module.constants.prod_openbao_seal_key_alias
}

module "platform" {
  source = "../../../modules/platform"

  stage = "prod"

  # fil-forge.com is served by Cloudflare and the service names sit directly
  # beneath it, so each one is delegated to a Route53 zone of its own, created
  # by terraform/envs/bootstrap/prod/account. A null zone_name selects that
  # layout: records and certificate validation go into each hostname's zone.
  zone_name = null

  hostname_suffix       = var.hostname_suffix
  ingot_hostname_suffix = var.ingot_hostname_suffix

  # The repository the bootstrap workspace for this account and region created.
  # Derived rather than copied from its output: a Lambda can pull only from its
  # own account and region, so those two values are the whole address.
  provision_image_repository_url = "${module.constants.prod_account_id}.dkr.ecr.${var.region}.amazonaws.com/${module.constants.provision_repository_name}"
  provision_image_digest         = var.provision_image_digest

  chain = var.chain

  appliance_regions         = var.appliance_regions
  retired_appliance_regions = var.retired_appliance_regions

  # Three availability zones with a NAT gateway in each, where dev accepts two
  # and a single shared gateway. Appliances depend on this stage being
  # reachable, so losing a zone must not cost it egress.
  #
  # az_count is fixed when the stage is created. Changing it later renumbers
  # the private subnets and replaces the database along with them; see the
  # network module's variable description before touching it.
  az_count           = 3
  nat_gateway_per_az = true

  # An Aurora cluster, sized for the launch rate of 12-22 PUT/s, about 150
  # commits/s for as long as uploads run. A burstable class would spend its CPU
  # credits within hours. The reader takes the writer's load after a failover,
  # so it has the same class. docs/decisions/2026-10-prod-first-stack.md has the
  # arithmetic and the costs.
  db_engine                = "aurora"
  db_instance_class        = "db.r8g.large"
  db_instance_count        = 2
  db_backup_retention_days = 35
  db_kms_key_arn           = data.aws_kms_alias.aurora.target_key_arn

  # Regional appliances cannot boot while OpenBao is unreachable, and OpenBao's
  # storage is this database.
  protect_stateful_resources = true

  # A db.r8g.large allows at most about 1,800 connections, and the stage needs
  # about 80 of them with OpenBao's 24 included.
  openbao_max_parallel = 24

  # Created by the regional bootstrap, like the cluster's key: OpenBao's storage
  # outlives this root, so the key it seals with has to as well.
  openbao_kms_key_arn = data.aws_kms_alias.openbao_seal.target_key_arn

  container_insights = true

  # Two static addresses an appliance operator can allowlist once, and an edge
  # that takes a flood before the load balancer does. Dev has neither need.
  enable_global_accelerator = true
}
