variable "stage" {
  type = string
}

variable "subnet_ids" {
  description = "Private subnets, at least two AZs."
  type        = list(string)
}

variable "security_group_id" {
  type = string
}

variable "engine_version" {
  type    = string
  default = "16"
}

variable "instance_class" {
  description = "Sized per stage. Mind max_connections, which scales with memory: roughly DBInstanceClassMemory/9531392, about 112 on a db.t4g.micro. OpenBao's max_parallel plus each service's max_conns has to fit inside it."
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage" {
  type    = number
  default = 20
}

variable "max_allocated_storage" {
  description = "Upper bound for storage autoscaling."
  type        = number
  default     = 100
}

variable "master_username" {
  type    = string
  default = "forge_admin"
}

variable "multi_az" {
  description = "Regional appliances cannot boot while OpenBao is down, and OpenBao stores its data here."
  type        = bool
  default     = true
}

variable "backup_retention_days" {
  type    = number
  default = 7
}

variable "deletion_protection" {
  type    = bool
  default = true
}

variable "skip_final_snapshot" {
  type    = bool
  default = false
}

variable "performance_insights_enabled" {
  type    = bool
  default = false
}
