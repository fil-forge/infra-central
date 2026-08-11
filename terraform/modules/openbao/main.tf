# The central OpenBao.
#
# It serves hilt's tenant secrets, and under fil-one/RFC#21 it is also the root
# of trust for regional appliances: each appliance's local OpenBao seals its
# storage with seal "transit" against this instance, authenticating here at
# boot to unseal. That is why it has a public hostname rather than living only
# on the private namespace, and why its availability is load-bearing.
#
# Three departures from smelt's Vault, all forced by Fargate having no durable
# local disk and no operator at the console:
#
#   storage    Postgres on the shared RDS, not raft on a volume.
#   seal       KMS, so there is no unseal key, no 1Password item holding it,
#              and no sidecar polling to apply it.
#   auth       hilt gets an AppRole scoped to its own mount, not the root token.

locals {
  name = "forge-${var.stage}-openbao"

  config_path = "/run/forge/openbao.hcl"

  # Written by the entrypoint rather than baked into the image because the
  # connection URL carries a password and OpenBao's HCL does not interpolate
  # environment variables. The heredoc is unquoted so the shell expands the one
  # secret; every other value is fixed by Terraform.
  config = <<-HCL
    storage "postgresql" {
      connection_url = "$OPENBAO_POSTGRES_DSN"
      max_parallel   = ${var.max_parallel}
      ha_enabled     = "false"
    }

    listener "tcp" {
      address     = "0.0.0.0:${var.port}"
      tls_disable = 1
    }

    seal "awskms" {
      region     = "${var.region}"
      kms_key_id = "${var.kms_key_id}"
    }

    api_addr      = "https://${var.hostname}"
    disable_mlock = true
    ui            = ${var.enable_ui}
  HCL

  shell_command = "bao server -config=${local.config_path}"
}

module "service" {
  source = "../ecs-service"

  stage      = var.stage
  service    = "openbao"
  region     = var.region
  account_id = var.account_id

  image          = var.image
  container_port = var.port

  cluster_arn       = var.cluster_arn
  vpc_id            = var.vpc_id
  subnet_ids        = var.subnet_ids
  security_group_id = var.security_group_id
  kms_key_arn       = var.kms_key_arn

  secrets = {
    OPENBAO_POSTGRES_DSN = "${var.ssm_prefix}/postgres-dsn"
  }

  # TLS terminates at the ALB, so the listener above is plaintext inside the
  # VPC. Both hilt and the provision Lambda reach it that way.
  environment = {
    BAO_ADDR = "http://127.0.0.1:${var.port}"
  }

  # The config is assembled here rather than through secret_files because it is
  # a template around a secret, not a secret in its own right. The heredoc
  # delimiter is deliberately unquoted so the shell substitutes the DSN; the
  # config contains no other shell metacharacters.
  shell_command = join("\n", [
    "umask 077",
    "mkdir -p ${dirname(local.config_path)}",
    "cat > ${local.config_path} <<EOF",
    local.config,
    "EOF",
    local.shell_command,
  ])

  # uninitcode=200 matters: a fresh OpenBao answers /sys/health with 501 until
  # it is initialised, and the provision Lambda cannot initialise a task that
  # ECS has already killed for failing its health check. A sealed instance
  # still reports 503, because with a KMS seal that is a real fault.
  health_check_path    = "/v1/sys/health?standbyok=true&uninitcode=200"
  health_check_command = "wget -q -O - http://127.0.0.1:${var.port}/v1/sys/health?standbyok=true\\&uninitcode=200 > /dev/null"

  hostname          = var.hostname
  listener_arn      = var.listener_arn
  listener_priority = var.listener_priority
  route53_zone_id   = var.route53_zone_id
  alb_dns_name      = var.alb_dns_name
  alb_zone_id       = var.alb_zone_id

  register_internal = true
  namespace_id      = var.namespace_id
  namespace_name    = var.namespace_name

  task_policy_json = data.aws_iam_policy_document.seal.json

  # Raising this needs ha_enabled in the storage stanza above. Until then a
  # second task would be a second writer, not a standby.
  desired_count = 1

  cpu    = var.cpu
  memory = var.memory
}

# Unsealing is a direct KMS operation, so unlike the parameter-decryption grant
# this one carries no kms:ViaService condition.
data "aws_iam_policy_document" "seal" {
  statement {
    sid       = "UnsealWithKMS"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey"]
    resources = [var.kms_key_arn]
  }
}
