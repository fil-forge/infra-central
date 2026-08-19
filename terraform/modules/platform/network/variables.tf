variable "stage" {
  description = "Deployment stage, e.g. dev or prod. Namespaces every resource."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC. Must leave room for two /20 subnets per availability zone, one public and one private."
  type        = string
  default     = "10.20.0.0/16"
}

variable "az_count" {
  description = <<-EOT
    Availability zones the stage spans. Two is the minimum both RDS multi-AZ
    and the ALB require; prod runs three.

    Set once, when the stage is created, and not changed afterwards. Private
    subnets are numbered from this value, so changing it renumbers every
    private subnet, which rewrites the database subnet group, which the
    database module's replace_triggered_by turns into a replaced RDS instance
    — and that instance is OpenBao's storage. Build a new stage rather than
    re-cutting a live one.
  EOT
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 4
    error_message = "az_count must be between 2 and 4, and the region must have at least that many availability zones."
  }
}

variable "nat_gateway_per_az" {
  description = <<-EOT
    Give each availability zone its own NAT gateway and private route table
    instead of sharing one pair. Removes the single point of failure in the
    stage's egress path, at roughly az_count times the NAT standing cost.

    Unlike az_count this is safe to change on a live stage: the extra
    gateways are additive and the subnet associations re-point in place.
  EOT
  type        = bool
  default     = false
}

variable "flow_log_retention_days" {
  description = "How long VPC flow logs are kept. They are the only record of traffic a security group dropped, which is worth having for longer than a debugging session but is not an audit artifact."
  type        = number
  default     = 30
}
