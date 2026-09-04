# Staging platform: VPC, RDS, S3, DynamoDB, ALB, OpenBao and the provision Lambda.
#
# .github/workflows/check-and-deploy.yml applies this root on every push to main, then
# applies envs/staging/apps, which reads its state. The two are ordered by a `needs:`
# edge between the jobs, because apps must not plan against outputs an in-flight
# platform apply is about to change.

provider "aws" {
  region = var.region

  # Credentials for another account would otherwise apply a second, quietly
  # working copy of the stage there. This fails the plan instead.
  allowed_account_ids = [module.constants.nonprod_account_id]

  default_tags {
    tags = {
      Project = "forge-central"
      Stage   = "staging"
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
  description = "Suffix every central service hostname shares. Stated explicitly because the hosted-zone delegation and stage-specific hostname shape differ."
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

# Seeded from the digest already deployed to dev. Promote a Lambda build to
# staging by copying dev's provision_image_digest after it is healthy there.
variable "provision_image_digest" {
  type = string
}

module "platform" {
  source = "../../../modules/platform"

  stage                 = "staging"
  zone_name             = var.zone_name
  hostname_suffix       = var.hostname_suffix
  ingot_hostname_suffix = var.ingot_hostname_suffix

  # The repository the bootstrap workspace for this account and region created.
  # Derived rather than copied from its output: a Lambda can pull only from its
  # own account and region, so those two values are the whole address.
  provision_image_repository_url = "${module.constants.nonprod_account_id}.dkr.ecr.${var.region}.amazonaws.com/${module.constants.provision_repository_name}"
  provision_image_digest         = var.provision_image_digest

  chain = var.chain

  appliance_regions         = var.appliance_regions
  retired_appliance_regions = var.retired_appliance_regions

  # Staging keeps one database instance, while giving the shared Postgres and
  # OpenBao workload twice dev's memory and connection budget.
  db_instance_class        = "db.t4g.small"
  db_allocated_storage     = 20
  db_multi_az              = false
  db_backup_retention_days = 7

  # Staging holds the root of trust for an appliance. Protect its RDS instance,
  # ALB and DynamoDB tables from deletion, retain a final database snapshot and
  # enable point-in-time recovery on both tables.
  protect_stateful_resources = true

  # A db.t4g.small allows roughly 225 connections. OpenBao takes 16, leaving
  # ample headroom for the application services' connection pools.
  openbao_max_parallel = 16

  # Bumped to re-issue proofs with the stable service identities from the Forge
  # identity RFC. Stored proofs retain their original issuer and audience, so a
  # hostname migration must explicitly replace them.
  seed_trigger = "3"
}
