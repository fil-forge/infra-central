variable "stage" {
  type = string
}

variable "zone_name" {
  description = "Existing Route53 hosted zone every public record goes into, e.g. staging.fil-forge.com. Null means each hostname is its own delegated zone, named after the hostname, which is how prod is laid out."
  type        = string
  default     = null
}

variable "hostname_suffix" {
  description = "Suffix every service hostname shares, e.g. dev.fil.one. Services are reachable at <service>.<suffix>."
  type        = string
}

variable "hostnames" {
  description = "Every public hostname the stage serves. The certificate covers them, and route53_zone_ids maps each one to the zone its records go into."
  type        = list(string)

  validation {
    condition     = length(var.hostnames) > 0
    error_message = "hostnames is empty. A stage with no public hostname has nothing to certify, and a null zone_name would leave the certificate without a name."
  }
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "security_group_id" {
  type = string
}

variable "idle_timeout" {
  description = "Seconds. Must exceed the quiet period of swarf's SSE firehose, not just its request time."
  type        = number
  default     = 3600
}

variable "deletion_protection" {
  type    = bool
  default = true
}

variable "enable_global_accelerator" {
  description = <<-EOT
    Front the load balancer with AWS Global Accelerator: two static anycast
    addresses an operator can allowlist once, a shorter handshake for distant
    clients, and Shield Standard applied at the edge.

    Off in dev, where it would be a standing charge for none of those. Safe to
    turn on or off on a live stage: the public_dns_name and public_zone_id
    outputs switch, and every service's alias record follows on the next apply.
  EOT
  type        = bool
  default     = false
}

variable "access_log_retention_days" {
  description = "How long ALB access logs are kept. Longer than the service logs on purpose: these are what an investigation starts from, and an incident is often noticed well after the request that caused it."
  type        = number
  default     = 90
}
