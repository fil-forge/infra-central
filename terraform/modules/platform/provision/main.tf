# The provision Lambda.
#
# This is where every secret in the stage is born. Terraform invokes the
# function and receives DIDs, wallet addresses and database names; the private
# keys behind them are written straight to SSM and never cross this boundary.
#
# The function runs in two phases because the dependency is circular: OpenBao
# stores its data in Postgres, so its database must exist before it starts, but
# it must be running before it can be configured. Terraform drives both phases
# from the calling root; see the note at the end of this file.

locals {
  name = "fc-${var.stage}-provision"
}

resource "aws_lambda_function" "this" {
  function_name = local.name
  role          = aws_iam_role.this.arn
  package_type  = "Image"

  # A digest, not a tag. The image can then never move underneath a deploy, and
  # an identical rebuild produces no diff here at all.
  image_uri = "${var.image_repository_url}@${var.image_digest}"

  architectures = ["arm64"]

  # Generous because the first run of a stage waits for the OpenBao task to
  # finish a cold start before it can configure it.
  timeout     = 600
  memory_size = 512

  # Naming the log group here rather than letting AWS create it on the first
  # invocation is what makes the retention setting stick: an auto-created group
  # keeps logs forever, and the resource below then collides with it.
  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.this.name
  }

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [var.security_group_id]
  }

  environment {
    variables = {
      FORGE_STAGE                 = var.stage
      FORGE_HOSTNAME_SUFFIX       = var.hostname_suffix
      FORGE_INGOT_HOSTNAME_SUFFIX = var.ingot_hostname_suffix
      FORGE_DB_HOST               = var.db_host
      FORGE_DB_PORT               = tostring(var.db_port)
      FORGE_DB_MASTER_SECRET_ARN  = var.db_master_secret_arn
      FORGE_OPENBAO_ADDR          = var.openbao_address
      FORGE_PRIVATE_CIDRS         = join(",", var.private_cidrs)

      # Used only by the onboard phase, which Terraform never invokes. The phase
      # reaches sprue and hilt at their public hostnames, built from
      # FORGE_HOSTNAME_SUFFIX above, out through the NAT gateway — the same path
      # hilt already takes to resolve sprue's did:web document.
      FORGE_ALLOW_LIST_TABLE = var.allow_list_table_name

      # Used only by the fund phase, which Terraform never invokes.
      FORGE_CHAIN_RPC_URL        = var.chain.rpc_url
      FORGE_CHAIN_ID             = tostring(var.chain.chain_id)
      FORGE_USDFC_ADDRESS        = var.chain.contracts.usdfc_token
      FORGE_FILECOIN_PAY_ADDRESS = var.chain.contracts.filecoin_pay
      FORGE_FWSS_ADDRESS         = var.chain.contracts.fwss
    }
  }

  tags = { Name = local.name }
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/lambda/${local.name}"
  retention_in_days = var.log_retention_days
}

# The invocations live in the calling root rather than here, because the two
# phases sit on opposite sides of OpenBao: seed must finish before OpenBao
# starts (it creates OpenBao's database), and vault cannot run until OpenBao is
# serving. A module can only carry one depends_on, so splitting them out is
# what lets each take the dependency it actually has.
