# Everything in a stage that changes rarely: network, database, storage,
# ingress, OpenBao, and the Lambda that mints the stage's secrets.
#
# This composite exists so each stage root stays a short list of what differs.
# Duplicating the wiring per stage would be the fastest route to two stages
# that quietly stopped resembling each other.
#
# The bootstrap order below is the load-bearing part:
#
#   database  ->  seed  ->  openbao  ->  vault
#
# seed creates OpenBao's own database, so it must finish before OpenBao starts.
# vault configures a running OpenBao, so it cannot run until the service is up.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

module "constants" {
  source = "../shared/constants"
}

locals {
  name       = "fc-${var.stage}"
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region

  # Every public hostname in the stage, OpenBao's and the apps root's alike,
  # because the ingress module certifies all of them.
  public_hostnames = {
    for service, label in module.constants.public_hostname_labels :
    service => "${label}.${var.hostname_suffix}"
  }
}

module "network" {
  source = "./network"

  stage              = var.stage
  vpc_cidr           = var.vpc_cidr
  az_count           = var.az_count
  nat_gateway_per_az = var.nat_gateway_per_az
  database_subnets   = var.db_engine == "aurora"
}

# Created only for a stage that brings no seal key of its own.
module "kms" {
  source = "./kms"
  count  = var.openbao_kms_key_arn == null ? 1 : 0

  stage                   = var.stage
  deletion_window_in_days = var.protect_stateful_resources ? 30 : 7
}

moved {
  from = module.kms
  to   = module.kms[0]
}

# One of the two database modules exists, chosen by db_engine. Both export the
# same four outputs, so everything below reads local.database and neither knows
# which engine it is talking to.
module "database" {
  source = "./database"
  count  = var.db_engine == "rds" ? 1 : 0

  stage             = var.stage
  subnet_ids        = module.network.private_subnet_ids
  security_group_id = module.network.database_security_group_id

  instance_class        = var.db_instance_class
  allocated_storage     = var.db_allocated_storage
  multi_az              = var.db_multi_az
  backup_retention_days = var.db_backup_retention_days
  deletion_protection   = var.protect_stateful_resources
  skip_final_snapshot   = !var.protect_stateful_resources
}

# The database module had no count before db_engine existed. This keeps the
# instance in dev and staging where it is instead of replacing it.
moved {
  from = module.database
  to   = module.database[0]
}

module "aurora" {
  source = "./aurora"
  count  = var.db_engine == "aurora" ? 1 : 0

  stage             = var.stage
  subnet_ids        = module.network.database_subnet_ids
  security_group_id = module.network.database_security_group_id
  kms_key_arn       = var.db_kms_key_arn

  instance_class        = var.db_instance_class
  instance_count        = var.db_instance_count
  backup_retention_days = var.db_backup_retention_days
  deletion_protection   = var.protect_stateful_resources
  skip_final_snapshot   = !var.protect_stateful_resources
}

locals {
  database = one(concat(module.database, module.aurora))
}

# The compatibility server's database, on a cluster of its own that the
# server's appliances reach over the stage's site-to-site VPN.
module "compat_database" {
  source = "./compat-database"
  count  = var.compat_database == null ? 0 : 1

  stage                    = var.stage
  vpc_id                   = module.network.vpc_id
  vpc_cidr                 = var.vpc_cidr
  availability_zones       = module.network.azs
  lambda_security_group_id = module.network.lambda_security_group_id
  kms_key_arn              = var.db_kms_key_arn
  sites                    = local.compat_server_sites

  instance_count        = var.compat_database.instance_count
  backup_retention_days = var.compat_database.backup_retention_days
  protect               = var.compat_database.protect
}

locals {
  compat_server_sites = lookup(module.constants.compat_server_sites, var.stage, {})
}

# Sites without the cluster are allowed: the regional bootstrap brings the VPN
# up before the cluster exists, and dropping the cluster keeps the tunnels. Left
# that way for long, though, the stage pays for a VPN with nothing behind it.
check "compat_server_sites_have_a_cluster" {
  assert {
    condition     = var.compat_database != null || length(local.compat_server_sites) == 0
    error_message = "Stage ${var.stage} has compatibility server sites (${join(", ", keys(local.compat_server_sites))}) but no compat_database, so their VPN connections cost about $44 a month each with no cluster to reach. Set compat_database, or remove the sites and apply the regional bootstrap."
  }
}

module "storage" {
  source = "./storage"

  stage                  = var.stage
  force_destroy          = !var.protect_stateful_resources
  point_in_time_recovery = var.protect_stateful_resources
  deletion_protection    = var.protect_stateful_resources
}

module "ingress" {
  source = "./ingress"

  stage                     = var.stage
  zone_name                 = var.zone_name
  hostname_suffix           = var.hostname_suffix
  hostnames                 = values(local.public_hostnames)
  public_subnet_ids         = module.network.public_subnet_ids
  security_group_id         = module.network.alb_security_group_id
  deletion_protection       = var.protect_stateful_resources
  enable_global_accelerator = var.enable_global_accelerator
}

resource "aws_ecs_cluster" "this" {
  name = local.name

  setting {
    name  = "containerInsights"
    value = var.container_insights ? "enabled" : "disabled"
  }
}

# The role CloudWatch Logs assumes to ship this stage's log groups to Grafana,
# and the ARN of the Firehose it ships them to. The Firehose is created by the
# regional bootstrap root; this only names it. Every module below that owns a
# log group takes the pair, and the apps root reads it from this root's outputs.
# A stage without a Firehose, which is what a personal sandbox is, turns the
# module off and every consumer receives null instead of the pair.
module "log_forwarding" {
  source = "./log-forwarding"
  count  = var.enable_log_forwarding ? 1 : 0

  stage      = var.stage
  region     = local.region
  account_id = local.account_id
}

locals {
  log_forwarding = one(module.log_forwarding[*].log_forwarding)
}

module "provision" {
  source = "./provision"

  stage      = var.stage
  region     = local.region
  account_id = local.account_id

  log_forwarding = local.log_forwarding

  hostname_suffix       = var.hostname_suffix
  ingot_hostname_suffix = var.ingot_hostname_suffix
  chain                 = var.chain
  image_repository_url  = var.provision_image_repository_url
  image_digest          = var.provision_image_digest

  subnet_ids        = module.network.private_subnet_ids
  security_group_id = module.network.lambda_security_group_id

  db_host                      = local.database.address
  db_port                      = local.database.port
  db_master_secret_arn         = local.database.master_secret_arn
  db_master_secret_kms_key_arn = local.database.master_secret_kms_key_arn

  pandora_db = var.compat_database == null ? null : {
    host                      = module.compat_database[0].address
    port                      = module.compat_database[0].port
    master_secret_arn         = module.compat_database[0].master_secret_arn
    master_secret_kms_key_arn = module.compat_database[0].master_secret_kms_key_arn
  }

  openbao_address = "http://openbao.${module.network.namespace_name}:8200"
  private_cidrs   = module.network.private_subnet_cidrs

  allow_list_table_name = module.storage.allow_list_table_name
  allow_list_table_arn  = module.storage.allow_list_table_arn
}

# Mints every identity, wallet and password, and creates the per-service
# databases. Safe to re-run at any time: nothing that already exists is
# regenerated, which is what protects the funded wallets.
resource "aws_lambda_invocation" "seed" {
  function_name = module.provision.function_name

  # The pandora host is here so that creating or replacing that cluster
  # re-invokes the phase. The function reads the host from its environment.
  input = jsonencode({
    phase           = "seed"
    trigger         = var.seed_trigger
    pandora_db_host = try(module.compat_database[0].address, null)
  })

  # Static references only: depends_on cannot read local.database, and only one
  # of the two modules exists.
  depends_on = [module.database, module.aurora, module.compat_database]
}

module "openbao" {
  source = "./openbao"

  stage      = var.stage
  region     = local.region
  account_id = local.account_id

  image        = var.openbao_image
  max_parallel = var.openbao_max_parallel
  hostname     = local.public_hostnames.openbao

  cluster_arn       = aws_ecs_cluster.this.arn
  vpc_id            = module.network.vpc_id
  subnet_ids        = module.network.private_subnet_ids
  security_group_id = module.network.service_security_group_id
  alb_cidrs         = module.network.public_subnet_cidrs

  # KMS accepts an ARN wherever it takes a key id, and the seal stanza is the
  # only place OpenBao uses the id.
  kms_key_id  = coalesce(var.openbao_kms_key_arn, one(module.kms[*].key_id))
  kms_key_arn = coalesce(var.openbao_kms_key_arn, one(module.kms[*].key_arn))
  ssm_prefix  = "/forge-central/${var.stage}/openbao"

  listener_arn      = module.ingress.listener_arn
  listener_priority = 100
  route53_zone_id   = module.ingress.route53_zone_ids[local.public_hostnames.openbao]
  alb_dns_name      = module.ingress.public_dns_name
  alb_zone_id       = module.ingress.public_zone_id

  namespace_id   = module.network.namespace_id
  namespace_name = module.network.namespace_name

  log_forwarding = local.log_forwarding

  # OpenBao's database is created by the seed phase.
  depends_on = [aws_lambda_invocation.seed]
}

# Initialises OpenBao, mounts KV v2 at forge-central/hilt and the transit
# engine, and issues hilt's AppRole. The function waits out the task's cold
# start, so this is slow on the first apply of a stage and fast afterwards.
resource "aws_lambda_invocation" "vault" {
  function_name = module.provision.function_name

  # The region lists are part of the input, so committing a label is what
  # re-invokes the phase to reconcile the keys against it.
  input = jsonencode({
    phase                     = "vault"
    trigger                   = var.vault_trigger
    appliance_regions         = var.appliance_regions
    retired_appliance_regions = var.retired_appliance_regions
  })

  depends_on = [module.openbao]
}
