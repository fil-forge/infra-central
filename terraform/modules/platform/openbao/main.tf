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
  config_path = "/tmp/forge/openbao.hcl"

  # Written by the entrypoint rather than baked into the image because the
  # connection URL carries a password and OpenBao's HCL does not interpolate
  # environment variables. The heredoc is unquoted so the shell expands the one
  # secret; every other value is fixed by Terraform.
  config = <<-HCL
    storage "postgresql" {
      connection_url = "$OPENBAO_POSTGRES_DSN"
      max_parallel   = "${var.max_parallel}"
      ha_enabled     = "false"
    }

    listener "tcp" {
      address     = "0.0.0.0:${var.port}"
      tls_disable = 1
  
      # An appliance authenticates here with a token bound to its Elastic IP,
      # and it arrives through the ALB, which connects from its own address.
      # Checking the raw connection would compare the ALB against the node's
      # address and refuse every one of those tokens at first unseal.
      #
      # The ALB appends the caller's address as the last entry of
      # X-Forwarded-For, and with no hops skipped that last entry is what the
      # listener takes as the client. A header a client sends itself arrives
      # earlier in the chain and loses to the append.
      x_forwarded_for_authorized_addrs = "${join(",", var.alb_cidrs)}"
      x_forwarded_for_hop_skips        = 0

      # hilt and the provision Lambda connect directly inside the VPC and send
      # no header, so a request without one is checked on its own address.
      # One that carries a header from anywhere but the ALB is refused rather
      # than quietly downgraded, which turns a workload trying to claim a
      # node's address into an error somebody sees.
      x_forwarded_for_reject_not_present    = false
      x_forwarded_for_reject_not_authorized = true
    }

    seal "awskms" {
      region     = "${var.region}"
      kms_key_id = "${var.kms_key_id}"
    }

    api_addr      = "https://${var.hostname}"
    disable_mlock = true
    ui            = ${var.enable_ui}
  HCL

  # exec, via dumb-init, because setting shell_command replaces the image
  # entrypoint with /bin/sh -c. Without exec, bao runs as a child of that shell
  # and never sees the SIGTERM ECS sends, so a deployment ends in a forced kill
  # once the stop timeout expires — expensive with desired_count = 1. dumb-init
  # is what upstream's entrypoint runs as PID 1 (`#!/usr/bin/dumb-init /bin/sh`)
  # to forward signals and reap children; the rest of that entrypoint only fills
  # in dev-mode flags and drops a root privilege this image never holds.
  shell_command = "exec dumb-init bao server -config=${local.config_path}"
}

module "service" {
  source = "../../shared/ecs-service"

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

  secrets = {
    OPENBAO_POSTGRES_DSN = "arn:aws:ssm:${var.region}:${var.account_id}:parameter${var.ssm_prefix}/postgres-dsn"
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

  task_policies = { "service-permissions" = data.aws_iam_policy_document.seal.json }

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
