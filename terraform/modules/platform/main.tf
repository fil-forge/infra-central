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

locals {
  name       = "fc-${var.stage}"
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
}

module "network" {
  source = "./network"

  stage              = var.stage
  vpc_cidr           = var.vpc_cidr
  az_count           = var.az_count
  nat_gateway_per_az = var.nat_gateway_per_az
}

module "kms" {
  source = "./kms"

  stage                   = var.stage
  deletion_window_in_days = var.protect_stateful_resources ? 30 : 7
}

module "database" {
  source = "./database"

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

module "provision" {
  source = "./provision"

  stage      = var.stage
  region     = local.region
  account_id = local.account_id

  hostname_suffix      = var.hostname_suffix
  chain                = var.chain
  image_repository_url = var.provision_image_repository_url
  image_digest         = var.provision_image_digest

  subnet_ids        = module.network.private_subnet_ids
  security_group_id = module.network.lambda_security_group_id

  db_host                      = module.database.address
  db_port                      = module.database.port
  db_master_secret_arn         = module.database.master_secret_arn
  db_master_secret_kms_key_arn = module.database.master_secret_kms_key_arn

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

  input = jsonencode({
    phase   = "seed"
    trigger = var.seed_trigger
  })

  depends_on = [module.database]
}

module "openbao" {
  source = "./openbao"

  stage      = var.stage
  region     = local.region
  account_id = local.account_id

  image        = var.openbao_image
  max_parallel = var.openbao_max_parallel
  hostname     = "ssm.${var.hostname_suffix}"

  cluster_arn       = aws_ecs_cluster.this.arn
  vpc_id            = module.network.vpc_id
  subnet_ids        = module.network.private_subnet_ids
  security_group_id = module.network.service_security_group_id
  alb_cidrs         = module.network.public_subnet_cidrs

  kms_key_id  = module.kms.key_id
  kms_key_arn = module.kms.key_arn
  ssm_prefix  = "/forge-central/${var.stage}/openbao"

  listener_arn      = module.ingress.listener_arn
  listener_priority = 100
  route53_zone_id   = module.ingress.route53_zone_id
  alb_dns_name      = module.ingress.public_dns_name
  alb_zone_id       = module.ingress.public_zone_id

  namespace_id   = module.network.namespace_id
  namespace_name = module.network.namespace_name

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
