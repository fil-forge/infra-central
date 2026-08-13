variable "stage" {
  type = string
}

variable "zone_name" {
  description = "Existing Route53 hosted zone, e.g. fil.one."
  type        = string
}

variable "hostname_suffix" {
  description = "Suffix every service hostname shares, e.g. dev.fil.one. Services are reachable at <service>.<suffix>."
  type        = string
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
