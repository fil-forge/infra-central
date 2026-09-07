variable "stage" {
  type = string
}

variable "region" {
  type = string
}

variable "account_id" {
  type = string
}

variable "image_repository_url" {
  description = "ECR repository URL for the provision image, from the bootstrap workspace for this stage's region."
  type        = string
}

variable "image_digest" {
  description = "Manifest digest written by `make publish`, e.g. sha256:abc... Dev reads it from the committed image.auto.tfvars that command writes; prod pins it in terraform.tfvars."
  type        = string

  validation {
    condition     = can(regex("^sha256:[0-9a-f]{64}$", var.image_digest))
    error_message = "image_digest must be a sha256 manifest digest. Run `make publish`, which writes one for the dev stage and prints the line to commit for prod."
  }
}

variable "subnet_ids" {
  description = "Private subnets. The function needs a route to RDS and to OpenBao."
  type        = list(string)
}

variable "security_group_id" {
  type = string
}

variable "hostname_suffix" {
  description = "Builds the did:web identities the startup proofs are addressed to, e.g. dev.fil.one."
  type        = string
}

variable "ingot_hostname_suffix" {
  description = "Builds region-qualified Ingot did:web identities."
  type        = string
}

variable "chain" {
  description = "Chain and contract configuration for the stage. Single source of truth: the apps workspace reads it from this workspace's outputs rather than keeping its own copy, mirroring smelt's shared smart-contracts.env."
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

variable "db_host" {
  type = string
}

variable "db_port" {
  type    = number
  default = 5432
}

variable "db_master_secret_arn" {
  type = string
}

variable "db_master_secret_kms_key_arn" {
  type = string
}

variable "openbao_address" {
  description = "Internal OpenBao URL. Only the vault phase uses it."
  type        = string
  default     = ""
}

variable "private_cidrs" {
  description = <<-EOT
    VPC private subnets, used to bound hilt's AppRole token.

    The vault phase requires them and fails when the list is empty, so an
    unbounded credential cannot be minted by omission. The default is empty
    because a stage that never runs that phase has no use for the value.
  EOT
  type        = list(string)
  default     = []
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "allow_list_table_name" {
  description = "The delegator's allow-list table. Only the onboard phase writes it."
  type        = string
}

variable "allow_list_table_arn" {
  description = "ARN of the same table, which is what the role is granted on."
  type        = string
}
