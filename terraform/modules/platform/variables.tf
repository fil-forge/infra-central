variable "stage" {
  type = string
}

variable "zone_name" {
  description = "Existing Route53 hosted zone, e.g. fil.one."
  type        = string
}

variable "hostname_suffix" {
  description = "Suffix every service hostname shares, e.g. dev.fil.one."
  type        = string
}

variable "ingot_hostname_suffix" {
  description = "Suffix for region-qualified Ingot identities, e.g. latest.dev.filonecontent.com."
  type        = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "provision_image_repository_url" {
  description = "ECR repository URL from the bootstrap workspace for this stage's region."
  type        = string
}

variable "provision_image_digest" {
  description = "Manifest digest from `make publish`. Dev reads it from the committed image.auto.tfvars that command writes; prod pins it in terraform.tfvars."
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

variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "db_allocated_storage" {
  type    = number
  default = 20
}

variable "db_multi_az" {
  type    = bool
  default = true
}

variable "db_backup_retention_days" {
  type    = number
  default = 7
}

variable "protect_stateful_resources" {
  description = "Deletion protection on RDS, the ALB and the delegator's DynamoDB tables, point-in-time recovery on those tables, and a final snapshot on destroy. Losing the database means losing OpenBao's storage and with it every appliance's ability to unseal."
  type        = bool
  default     = true
}

variable "az_count" {
  description = "Availability zones the stage spans. Two is the minimum RDS multi-AZ and the ALB require. Read the network module's variable of the same name before changing this on a stage that exists: it is a create-time decision, and getting it wrong replaces the database."
  type        = number
  default     = 2
}

variable "nat_gateway_per_az" {
  description = "One NAT gateway per availability zone instead of a single shared one. Removes the stage's one egress point of failure at roughly az_count times the cost, and unlike az_count is safe to change on a live stage."
  type        = bool
  default     = false
}

variable "enable_global_accelerator" {
  description = "Front the ALB with Global Accelerator for static anycast addresses and edge termination. Worth its standing charge on a stage regional appliances dial into, not on one nothing does."
  type        = bool
  default     = false
}

variable "openbao_image" {
  description = "OpenBao image, pinned by digest so a replacement task can never pull different bytes. The openbao module requires the digest."
  type        = string
  default     = "openbao/openbao:2.6.0@sha256:900bb64d0671cd1d82b693c56206f7263b582445f3a3bb6ba6e5213f524a6653"
}

variable "openbao_max_parallel" {
  description = "Postgres connections OpenBao may open. Budget against the instance's max_connections alongside the application services."
  type        = number
  default     = 16
}

variable "container_insights" {
  type    = bool
  default = false
}

variable "seed_trigger" {
  description = "Change to force the seed phase to run again."
  type        = string
  default     = "1"
}

variable "appliance_regions" {
  description = "Region labels of the appliances this stage serves. Each one gets a transit key its node's OpenBao seals against, created by the vault phase."
  type        = list(string)
  default     = []
}

variable "retired_appliance_regions" {
  description = "Region labels whose appliance has been retired. The vault phase revokes the node's unseal token and destroys its transit key, and a label named by neither list fails the phase, so a retired label has to stay here rather than being deleted."
  type        = list(string)
  default     = []
}

variable "vault_trigger" {
  description = "Change to force the vault phase to run again, for example after rotating hilt's AppRole."
  type        = string
  default     = "1"
}
