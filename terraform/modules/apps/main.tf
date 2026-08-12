# The six ECS services.
#
# Everything here is derived from the platform workspace's outputs plus the SSM
# parameters the provision Lambda wrote. No secret value appears in this
# configuration; only parameter ARNs, which ECS resolves at task start.
#
# Service-specific quirks worth knowing before reading further:
#
#   hilt, swarf    default to binding 127.0.0.1, so they need an explicit host
#   hilt, swarf    accept the identity key only as a file path
#   delegator      needs its UCAN proofs as files; the inline form panics
#   delegator      uses DynamoDB and no Postgres at all
#   plc            has no public hostname, matching smelt
#   health paths   /health, /healthcheck and /_health all appear below

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region

  ssm = "arn:aws:ssm:${local.region}:${local.account_id}:parameter/forge-central/${var.stage}"

  host = { for service in [
    "sprue", "hilt", "swarf", "delegator", "signing-service"
  ] : service => "${service}.${var.hostname_suffix}" }

  # Services address each other by did:web, which resolves over public HTTPS.
  # A task in a private subnet therefore reaches the public ALB back out
  # through the NAT gateway.
  url = { for service, hostname in local.host : service => "https://${hostname}" }

  did = { for service, hostname in local.host : service => "did:web:${hostname}" }

  plc_directory = "http://plc.${var.namespace_name}:3000"

  # Where the entrypoint wrapper drops file-borne secrets.
  keys = "/run/forge"
}

# --- sprue ---------------------------------------------------------------

module "sprue" {
  source = "../ecs-service"

  stage      = var.stage
  service    = "sprue"
  region     = local.region
  account_id = local.account_id

  image          = "ghcr.io/fil-forge/sprue@${var.image_digests.sprue}"
  container_port = 8080

  cluster_arn       = var.cluster_arn
  vpc_id            = var.vpc_id
  subnet_ids        = var.subnet_ids
  security_group_id = var.security_group_id
  kms_key_arn       = var.kms_key_arn

  environment = {
    SPRUE_SERVER_HOST          = "0.0.0.0"
    SPRUE_SERVER_PORT          = "8080"
    SPRUE_SERVER_PUBLIC_URL    = local.url.sprue
    SPRUE_IDENTITY_KEY_FILE    = "${local.keys}/identity.pem"
    SPRUE_IDENTITY_SERVICE_DID = local.did.sprue

    SPRUE_DEPLOYMENT_ENVIRONMENT                          = var.stage
    SPRUE_DEPLOYMENT_ALLOW_PROVISION_WITHOUT_PAYMENT_PLAN = tostring(var.allow_provision_without_payment_plan)
    SPRUE_DEPLOYMENT_PLC_DIRECTORY                        = local.plc_directory

    # Empty disables the indexer, as in smelt's staging config.
    SPRUE_INDEXER_ENDPOINT = ""
    SPRUE_INDEXER_DID      = ""

    SPRUE_STORAGE_TYPE = "postgres"

    # No endpoint means the AWS default credential chain, so S3 is reached
    # through the task role and there are no static keys anywhere. This is what
    # replaces smelt's MinIO root user and password.
    SPRUE_STORAGE_S3_REGION               = local.region
    SPRUE_STORAGE_S3_AGENT_MESSAGE_BUCKET = var.bucket_names["agent-message"]
    SPRUE_STORAGE_S3_DELEGATION_BUCKET    = var.bucket_names["delegation"]
    SPRUE_STORAGE_S3_UPLOAD_SHARDS_BUCKET = var.bucket_names["upload-shards"]

    SPRUE_MAILER_TYPE = "nop"
    SPRUE_LOG_LEVEL   = var.log_level
  }

  secrets = {
    SPRUE_STORAGE_POSTGRES_DSN = "${local.ssm}/sprue/postgres-dsn"
    SPRUE_IDENTITY_KEY_PEM     = "${local.ssm}/sprue/identity"
  }

  secret_files  = { SPRUE_IDENTITY_KEY_PEM = "identity.pem" }
  shell_command = "sprue serve"

  health_check_command = "curl -sf http://127.0.0.1:8080/health"
  health_check_path    = "/health"

  hostname          = local.host.sprue
  listener_arn      = var.listener_arn
  listener_priority = 110
  route53_zone_id   = var.route53_zone_id
  alb_dns_name      = var.alb_dns_name
  alb_zone_id       = var.alb_zone_id

  task_policies = { "service-permissions" = data.aws_iam_policy_document.sprue.json }

  cpu    = var.sizes.sprue.cpu
  memory = var.sizes.sprue.memory
}

data "aws_iam_policy_document" "sprue" {
  statement {
    sid       = "ObjectAccess"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
    resources = concat(var.bucket_arns, [for arn in var.bucket_arns : "${arn}/*"])
  }
}

# --- hilt ----------------------------------------------------------------

module "hilt" {
  source = "../ecs-service"

  stage      = var.stage
  service    = "hilt"
  region     = local.region
  account_id = local.account_id

  image          = "ghcr.io/fil-forge/hilt@${var.image_digests.hilt}"
  container_port = 8080

  cluster_arn       = var.cluster_arn
  vpc_id            = var.vpc_id
  subnet_ids        = var.subnet_ids
  security_group_id = var.security_group_id
  kms_key_arn       = var.kms_key_arn

  environment = {
    # hilt binds 127.0.0.1 by default, which no health check can reach.
    HILT_SERVER_HOST = "0.0.0.0"
    HILT_SERVER_PORT = "8080"

    HILT_IDENTITY_KEY_FILE   = "${local.keys}/identity.pem"
    HILT_IDENTITY_SERVICE_ID = local.did.hilt

    HILT_STORAGE_TYPE = "postgres"

    HILT_VAULT_TYPE                  = "hashicorp"
    HILT_VAULT_HASHICORP_ADDRESS     = var.openbao_internal_address
    HILT_VAULT_HASHICORP_AUTH_METHOD = "approle"
    # Mounting KV v2 at forge-central/hilt puts every tenant secret under that
    # prefix without changing hilt, whose path builder is already mount-relative.
    HILT_VAULT_HASHICORP_MOUNT = "forge-central/hilt"

    HILT_PLC_DIRECTORY = local.plc_directory

    HILT_UPLOAD_SERVICE_ID  = local.did.sprue
    HILT_UPLOAD_SERVICE_URL = local.url.sprue
    HILT_UPLOAD_PRODUCT_ID  = local.did.hilt
    HILT_UPLOAD_PROOFS      = "${local.keys}/upload-proof.txt"

    HILT_LOG_LEVEL = var.log_level
  }

  secrets = {
    HILT_STORAGE_POSTGRES_DSN              = "${local.ssm}/hilt/postgres-dsn"
    HILT_AUTH_PARTNER_KEY                  = "${local.ssm}/hilt/partner-key"
    HILT_VAULT_HASHICORP_APPROLE_ROLE_ID   = "${local.ssm}/hilt/vault-role-id"
    HILT_VAULT_HASHICORP_APPROLE_SECRET_ID = "${local.ssm}/hilt/vault-secret-id"
    HILT_IDENTITY_KEY_PEM                  = "${local.ssm}/hilt/identity"
    HILT_UPLOAD_PROOF                      = "${local.ssm}/hilt/upload-proof"
  }

  secret_files = {
    HILT_IDENTITY_KEY_PEM = "identity.pem"
    HILT_UPLOAD_PROOF     = "upload-proof.txt"
  }
  shell_command = "hilt serve"

  health_check_command = "curl -sf http://127.0.0.1:8080/health"
  health_check_path    = "/health"

  hostname          = local.host.hilt
  listener_arn      = var.listener_arn
  listener_priority = 120
  route53_zone_id   = var.route53_zone_id
  alb_dns_name      = var.alb_dns_name
  alb_zone_id       = var.alb_zone_id

  cpu    = var.sizes.hilt.cpu
  memory = var.sizes.hilt.memory
}

# --- swarf ---------------------------------------------------------------

module "swarf" {
  source = "../ecs-service"

  stage      = var.stage
  service    = "swarf"
  region     = local.region
  account_id = local.account_id

  image          = "ghcr.io/fil-forge/swarf@${var.image_digests.swarf}"
  container_port = 8080

  cluster_arn       = var.cluster_arn
  vpc_id            = var.vpc_id
  subnet_ids        = var.subnet_ids
  security_group_id = var.security_group_id
  kms_key_arn       = var.kms_key_arn

  environment = {
    SWARF_SERVER_HOST = "0.0.0.0"
    SWARF_SERVER_PORT = "8080"

    SWARF_IDENTITY_KEY_FILE   = "${local.keys}/identity.pem"
    SWARF_IDENTITY_SERVICE_ID = local.did.swarf

    SWARF_STORAGE_TYPE  = "postgres"
    SWARF_PLC_DIRECTORY = local.plc_directory
    SWARF_LOG_LEVEL     = var.log_level
  }

  secrets = {
    SWARF_STORAGE_POSTGRES_DSN = "${local.ssm}/swarf/postgres-dsn"
    SWARF_IDENTITY_KEY_PEM     = "${local.ssm}/swarf/identity"
  }

  secret_files  = { SWARF_IDENTITY_KEY_PEM = "identity.pem" }
  shell_command = "swarf serve"

  health_check_command = "curl -sf http://127.0.0.1:8080/health"
  health_check_path    = "/health"

  hostname          = local.host.swarf
  listener_arn      = var.listener_arn
  listener_priority = 130
  route53_zone_id   = var.route53_zone_id
  alb_dns_name      = var.alb_dns_name
  alb_zone_id       = var.alb_zone_id

  cpu    = var.sizes.swarf.cpu
  memory = var.sizes.swarf.memory
}

# --- delegator -----------------------------------------------------------

module "delegator" {
  source = "../ecs-service"

  stage      = var.stage
  service    = "delegator"
  region     = local.region
  account_id = local.account_id

  image          = "ghcr.io/fil-forge/delegator@${var.image_digests.delegator}"
  container_port = 8080

  cluster_arn       = var.cluster_arn
  vpc_id            = var.vpc_id
  subnet_ids        = var.subnet_ids
  security_group_id = var.security_group_id
  kms_key_arn       = var.kms_key_arn

  environment = {
    REGISTRAR_SERVER_HOST = "0.0.0.0"
    REGISTRAR_SERVER_PORT = "8080"

    # DynamoDB, reached through the task role. The delegator uses no Postgres.
    REGISTRAR_STORE_REGION                  = local.region
    REGISTRAR_STORE_ALLOWLIST_TABLE_NAME    = var.allow_list_table_name
    REGISTRAR_STORE_PROVIDERINFO_TABLE_NAME = var.provider_info_table_name

    REGISTRAR_DELEGATOR_DID = local.did.delegator

    # Both proofs must be files: the inline variants panic in current code.
    REGISTRAR_DELEGATOR_INDEXING_SERVICE_PROOF_FILE        = "${local.keys}/indexing-service-proof.txt"
    REGISTRAR_DELEGATOR_EGRESS_TRACKING_SERVICE_PROOF_FILE = "${local.keys}/egress-tracking-proof.txt"
    REGISTRAR_DELEGATOR_INDEXING_SERVICE_WEB_DID           = var.indexer_did
    REGISTRAR_DELEGATOR_EGRESS_TRACKING_SERVICE_DID        = var.etracker_did
    REGISTRAR_DELEGATOR_UPLOAD_SERVICE_DID                 = local.did.sprue

    REGISTRAR_CONTRACT_CHAIN_CLIENT_ENDPOINT     = var.chain.rpc_url
    REGISTRAR_CONTRACT_PAYMENTS_CONTRACT_ADDRESS = var.chain.contracts.filecoin_pay
    REGISTRAR_CONTRACT_SERVICE_CONTRACT_ADDRESS  = var.chain.contracts.fwss
    REGISTRAR_CONTRACT_REGISTRY_CONTRACT_ADDRESS = var.chain.contracts.service_provider_registry
    REGISTRAR_CONTRACT_TRANSACTOR_CHAIN_ID       = tostring(var.chain.chain_id)
  }

  secrets = {
    REGISTRAR_DELEGATOR_KEY           = "${local.ssm}/delegator/identity-multibase"
    REGISTRAR_CONTRACT_TRANSACTOR_KEY = "${local.ssm}/delegator/transactor-key"
    DELEGATOR_INDEXING_PROOF          = "${local.ssm}/delegator/indexing-service-proof"
    DELEGATOR_EGRESS_PROOF            = "${local.ssm}/delegator/egress-tracking-proof"
  }

  secret_files = {
    DELEGATOR_INDEXING_PROOF = "indexing-service-proof.txt"
    DELEGATOR_EGRESS_PROOF   = "egress-tracking-proof.txt"
  }
  shell_command = "registrar serve"

  # Alpine base: wget rather than curl. Note /healthcheck, not /health.
  health_check_command = "wget -q --spider http://127.0.0.1:8080/healthcheck"
  health_check_path    = "/healthcheck"

  hostname          = local.host.delegator
  listener_arn      = var.listener_arn
  listener_priority = 140
  route53_zone_id   = var.route53_zone_id
  alb_dns_name      = var.alb_dns_name
  alb_zone_id       = var.alb_zone_id

  task_policies = { "service-permissions" = data.aws_iam_policy_document.delegator.json }

  cpu    = var.sizes.delegator.cpu
  memory = var.sizes.delegator.memory
}

data "aws_iam_policy_document" "delegator" {
  statement {
    sid = "RegistryTables"

    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:DeleteItem",
      "dynamodb:Query",
      "dynamodb:Scan",
    ]

    resources = var.dynamodb_table_arns
  }
}

# --- signing service -----------------------------------------------------

module "signing_service" {
  source = "../ecs-service"

  stage      = var.stage
  service    = "signing-service"
  region     = local.region
  account_id = local.account_id

  image          = "ghcr.io/fil-forge/piri-signing-service@${var.image_digests.signing_service}"
  container_port = 7446

  cluster_arn       = var.cluster_arn
  vpc_id            = var.vpc_id
  subnet_ids        = var.subnet_ids
  security_group_id = var.security_group_id
  kms_key_arn       = var.kms_key_arn

  environment = {
    SIGNING_SERVICE_HOST                     = "0.0.0.0"
    SIGNING_SERVICE_PORT                     = "7446"
    SIGNING_SERVICE_RPC_URL                  = var.chain.rpc_url
    SIGNING_SERVICE_SERVICE_CONTRACT_ADDRESS = var.chain.contracts.fwss
    SIGNING_SERVICE_SERVICE_DID              = local.did["signing-service"]
  }

  # This service takes both keys inline, so it needs no file wrapper at all.
  secrets = {
    SIGNING_SERVICE_SERVICE_KEY = "${local.ssm}/signing-service/identity-multibase"
    SIGNING_SERVICE_SIGNING_KEY = "${local.ssm}/signing-service/payer-key"
  }

  health_check_command = "wget -q --spider http://127.0.0.1:7446/healthcheck"
  health_check_path    = "/healthcheck"

  hostname          = local.host["signing-service"]
  listener_arn      = var.listener_arn
  listener_priority = 150
  route53_zone_id   = var.route53_zone_id
  alb_dns_name      = var.alb_dns_name
  alb_zone_id       = var.alb_zone_id

  cpu    = var.sizes.signing_service.cpu
  memory = var.sizes.signing_service.memory
}

# --- plc directory -------------------------------------------------------

module "plc" {
  source = "../ecs-service"

  stage      = var.stage
  service    = "plc"
  region     = local.region
  account_id = local.account_id

  image          = "ghcr.io/fil-forge/did-method-plc@${var.image_digests.plc}"
  container_port = 3000

  cluster_arn       = var.cluster_arn
  vpc_id            = var.vpc_id
  subnet_ids        = var.subnet_ids
  security_group_id = var.security_group_id
  kms_key_arn       = var.kms_key_arn

  environment = {
    ENABLE_MIGRATIONS = "true"
    PORT              = "3000"
  }

  secrets = {
    DB_CREDS_JSON         = "${local.ssm}/plc/db-creds-json"
    DB_MIGRATE_CREDS_JSON = "${local.ssm}/plc/db-creds-json"
  }

  health_check_command = "wget -q --spider http://127.0.0.1:3000/_health"
  health_check_path    = "/_health"

  # No public hostname, matching smelt, which gives plc no route and no DNS
  # record. Only sprue and hilt call it, both from inside the VPC.
  hostname          = null
  register_internal = true
  namespace_id      = var.namespace_id
  namespace_name    = var.namespace_name

  cpu    = var.sizes.plc.cpu
  memory = var.sizes.plc.memory
}
