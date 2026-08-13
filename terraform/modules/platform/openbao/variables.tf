variable "stage" {
  type = string
}

variable "region" {
  type = string
}

variable "account_id" {
  type = string
}

variable "image" {
  description = "OpenBao image. 2.6.x is the series fil-one/RFC#21 benchmarked."
  type        = string
  default     = "openbao/openbao:2.6.0"
}

variable "port" {
  type    = number
  default = 8200
}

variable "max_parallel" {
  description = <<-EOT
    Postgres connections OpenBao may open. Its own default is 128, which is
    fine for a dedicated database and rude to one shared with four application
    services.

    Budget against the instance's real max_connections (roughly
    DBInstanceClassMemory/9531392, about 112 on a db.t4g.micro) alongside
    sprue, hilt and swarf, which each default to max_conns = 10. RDS Proxy is
    the escape hatch if the budget gets tight.
  EOT
  type        = number
  default     = 16

  validation {
    condition     = var.max_parallel >= 4 && var.max_parallel <= 64
    error_message = "max_parallel should stay between 4 and 64: below that OpenBao serialises under load, above it starves the application services of connections."
  }
}

variable "hostname" {
  description = "Public hostname. Regional appliances authenticate here at boot to unseal, so this cannot be internal-only."
  type        = string
}

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

variable "kms_key_id" {
  type = string
}

variable "kms_key_arn" {
  type = string
}

variable "ssm_prefix" {
  description = "Parameter prefix for openbao, e.g. /forge-central/dev/openbao."
  type        = string
}

variable "listener_arn" {
  type = string
}

variable "listener_priority" {
  type    = number
  default = 100
}

variable "route53_zone_id" {
  type = string
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
  type    = string
  default = "forge-central.internal"
}

variable "enable_ui" {
  type    = bool
  default = false
}

variable "cpu" {
  type    = number
  default = 512
}

variable "memory" {
  type    = number
  default = 1024
}
