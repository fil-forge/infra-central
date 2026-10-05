variable "stage" {
  type = string
}

variable "hostname_suffix" {
  type = string
}

# --- from the platform workspace ---

variable "cluster_arn" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "security_group_id" {
  type = string
}

variable "listener_arn" {
  type = string
}

variable "route53_zone_id" {
  description = "The zone every public hostname shares. Null where each hostname has a zone of its own; see route53_zone_ids."
  type        = string
  default     = null
}

variable "route53_zone_ids" {
  description = "Zone each public hostname's record goes into, keyed by hostname, for a stage whose hostnames each have a zone of their own."
  type        = map(string)
  default     = {}

  validation {
    condition     = (var.route53_zone_id == null) != (length(var.route53_zone_ids) == 0)
    error_message = "Set exactly one of route53_zone_id, for a zone the hostnames share, and route53_zone_ids, for a zone per hostname."
  }
}

variable "alb_dns_name" {
  type = string
}

variable "alb_zone_id" {
  type = string
}

variable "namespace_id" {
  type = string
}

variable "namespace_name" {
  type = string
}

variable "bucket_names" {
  type = map(string)
}

variable "bucket_arns" {
  type = list(string)
}

variable "allow_list_table_name" {
  type = string
}

variable "provider_info_table_name" {
  type = string
}

variable "dynamodb_table_arns" {
  type = list(string)
}

variable "openbao_internal_address" {
  type = string
}

variable "indexer_did" {
  description = "did:web of the indexing service the delegator delegates to. Not deployed yet; its identity key is minted so the proof can be signed."
  type        = string
}

variable "etracker_did" {
  description = "did:web of the egress tracking service. Same situation as the indexer."
  type        = string
}

# --- per-stage configuration ---

variable "image_digests" {
  description = "Image digest per service, pinned by every stage. A digest names one artifact and cannot move underneath a running service, so what a stage runs is a committed fact rather than whatever the tag pointed at when the task last started."
  type = object({
    sprue           = string
    hilt            = string
    swarf           = string
    delegator       = string
    signing_service = string
    plc             = string
  })

  validation {
    condition     = alltrue([for digest in values(var.image_digests) : startswith(digest, "sha256:")])
    error_message = "Every service must be pinned by digest, in the form sha256:<hex>. A tag here would produce an image reference that pulls at task start and fails there instead."
  }
}

variable "chain" {
  description = "Chain and contract configuration, read from the platform workspace so it has one home per stage. Only the delegator and signing service use the RPC, and both make plain request/response calls, so https works."
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

variable "allow_provision_without_payment_plan" {
  description = "Lets sprue provision storage with no payment plan attached. Off in every stage: hilt registers each tenant as a sprue customer through /customer/add, which is the plan sprue looks for."
  type        = bool
  default     = false
}

variable "log_level" {
  type    = string
  default = "info"
}

variable "sizes" {
  description = "Fargate CPU and memory per service."
  type = map(object({
    cpu    = number
    memory = number
  }))

  default = {
    sprue           = { cpu = 512, memory = 1024 }
    hilt            = { cpu = 512, memory = 1024 }
    swarf           = { cpu = 256, memory = 512 }
    delegator       = { cpu = 256, memory = 512 }
    signing_service = { cpu = 256, memory = 512 }
    plc             = { cpu = 256, memory = 512 }
  }
}

variable "sprue_postgres_max_conns" {
  description = "Size of sprue's Postgres connection pool. Null keeps sprue's default of 10. It counts against the database's max_connections together with every other service's pool and OpenBao's max_parallel."
  type        = number
  default     = null
}

variable "log_forwarding" {
  description = "Firehose ARN and the role CloudWatch Logs assumes to write to it, read from the platform root's outputs and passed to every service. Null leaves the log groups in CloudWatch only."
  type = object({
    firehose_arn = string
    role_arn     = string
  })
  default = null
}
