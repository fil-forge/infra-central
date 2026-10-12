variable "stage" {
  type = string
}

variable "name" {
  description = "Names the cluster, its instances (<name>-N), subnet group and parameter group. Defaults to fc-<stage>, the stage's own cluster; a second cluster in the same stage needs a name of its own. Changing it on a live cluster replaces the cluster."
  type        = string
  default     = null

  validation {
    condition     = var.name == null || can(regex("^fc-[a-z0-9]+(-[a-z0-9]+)*$", var.name))
    error_message = "name must start with fc- and contain only lowercase letters, digits and single hyphens, e.g. fc-prod-pandora-db."
  }
}

variable "subnet_ids" {
  description = "One subnet per availability zone, at least two. A live cluster cannot move to another subnet group, so these are fixed when the cluster is created."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "The cluster needs subnets in at least two availability zones."
  }
}

variable "security_group_id" {
  type = string
}

variable "kms_key_arn" {
  description = "Customer-managed key encrypting the cluster and its snapshots. A cluster cannot change its key without a restore into a new cluster, so the key must outlive the platform root."
  type        = string
}

variable "engine_version" {
  description = "Aurora PostgreSQL release, pinned to a minor version. 16 matches the RDS instances in dev and staging."
  type        = string
  default     = "16.15"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+$", var.engine_version))
    error_message = "The engine version must name a minor release, such as 16.15."
  }
}

variable "instance_class" {
  description = <<-EOT
    Class of every instance in the cluster. The readers share the writer's
    class because one of them takes the writer's load after a failover.

    max_connections is LEAST(DBInstanceClassMemory/9531392, 5000): at most
    about 1,800 on a db.r8g.large. OpenBao's max_parallel plus each service's
    max_conns has to fit inside it.
  EOT
  type        = string
  default     = "db.r8g.large"

  validation {
    condition     = !startswith(var.instance_class, "db.t")
    error_message = "Burstable classes run out of CPU credits under sustained writes, and Aurora Global Database does not support them."
  }
}

variable "instance_count" {
  description = "The writer plus its readers. Two puts a failover target in a second availability zone."
  type        = number
  default     = 2

  validation {
    condition     = var.instance_count >= 1
    error_message = "The cluster needs at least its writer."
  }
}

variable "master_username" {
  type    = string
  default = "forge_admin"
}

variable "backup_retention_days" {
  description = "Point-in-time recovery window. Aurora allows up to 35 days."
  type        = number
  default     = 35
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
  description = "Performance Insights on every instance, free at the seven-day retention pinned in main.tf. See the database module's variable of the same name."
  type        = bool
  default     = true
}
