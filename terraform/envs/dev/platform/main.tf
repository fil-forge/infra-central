# Dev platform: VPC, RDS, S3, DynamoDB, ALB, OpenBao and the provision Lambda.
#
# .github/workflows/check-and-deploy.yml applies this root on every push to main, then
# applies envs/dev/apps, which reads its state. The two are ordered by a `needs:`
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

variable "content_hostname_suffix" {
  description = "Where appliances serve S3, and what their Ingot did:web identities are named after, in terraform.tfvars."
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

# Written by `make publish` into image.auto.tfvars, so the dev loop is
# `make publish`, commit, merge, with nothing to edit by hand.
variable "provision_image_digest" {
  type = string
}

module "platform" {
  source = "../../../modules/platform"

  stage           = "dev"
  zone_name       = var.zone_name
  hostname_suffix = var.hostname_suffix

  # The repository the bootstrap workspace for this account and region created.
  # Derived rather than copied from its output: a Lambda can pull only from its
  # own account and region, so those two values are the whole address.
  provision_image_repository_url = "${module.constants.nonprod_account_id}.dkr.ecr.${var.region}.amazonaws.com/${module.constants.provision_repository_name}"
  provision_image_digest         = var.provision_image_digest

  chain = var.chain

  appliance_regions         = var.appliance_regions
  retired_appliance_regions = var.retired_appliance_regions
  content_hostname_suffix   = var.content_hostname_suffix

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

  # Bumped to re-issue the delegator's two proofs, which were deleted from SSM
  # so the seed phase would write them base64-encoded, and to rewrite plc's
  # db-creds-json with an sslmode RDS accepts.
  seed_trigger = "2"
}
