variable "stage" {
  type = string
}

variable "service" {
  description = "Service name. Also the SSM parameter prefix this task can read, so it must match what the provision Lambda wrote."
  type        = string
}

variable "region" {
  type = string
}

variable "account_id" {
  type = string
}

variable "image" {
  description = "Full image reference. Prefer a digest in prod so a deploy names exactly one artifact."
  type        = string
}

variable "container_port" {
  type = number
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

variable "environment" {
  description = "Plain environment variables. Never put a secret here: task definitions are readable by anyone with ecs:DescribeTaskDefinition."
  type        = map(string)
  default     = {}
}

variable "secrets" {
  description = "Environment variable name to SSM parameter ARN. ECS resolves these at task start."
  type        = map(string)
  default     = {}
}

variable "secret_files" {
  description = <<-EOT
    Environment variable name to filename, for secrets a service can only read
    from a file. The entrypoint wrapper writes each one into the module's
    secret_dir at 0400 before exec'ing the process.

    Needed because hilt and swarf accept their identity key only as a path, and
    the delegator's UCAN proofs are file-only in current code. Every key here
    must also appear in `secrets`, and setting this requires shell_command.
  EOT
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for env_var in keys(var.secret_files) : contains(keys(var.secrets), env_var)])
    error_message = "Every secret_files key must also be a secrets key: the wrapper writes an environment variable to a file, so ECS has to inject it first. A missing entry writes an empty file and the service fails at startup with an unhelpful parse error."
  }
}

variable "shell_command" {
  description = "Command to exec, as a shell string. Required when secret_files is set, because the wrapper replaces the image's entrypoint. Null uses the image's own entrypoint and command."
  type        = string
  default     = null

  validation {
    condition     = length(var.secret_files) == 0 || var.shell_command != null
    error_message = "secret_files replaces the image entrypoint with a wrapper, so shell_command must say what to exec afterwards."
  }
}

variable "health_check_command" {
  description = "Container-level health check. Base images differ: the debian-based services have curl, the alpine ones have wget."
  type        = string
}

variable "health_check_path" {
  description = "ALB health check path. /health for sprue, hilt and swarf; /healthcheck for the delegator and signing service; /_health for plc."
  type        = string
  default     = "/health"
}

variable "health_check_start_period" {
  description = "Seconds before health checks count. The Postgres-backed services run goose migrations during this window."
  type        = number
  default     = 90
}

variable "hostname" {
  description = "Public hostname. Null gives the service no ALB route and no public DNS, as with plc."
  type        = string
  default     = null
}

variable "listener_arn" {
  type    = string
  default = null
}

variable "listener_priority" {
  type    = number
  default = null
}

variable "route53_zone_id" {
  type    = string
  default = null
}

variable "alb_dns_name" {
  type    = string
  default = null
}

variable "alb_zone_id" {
  type    = string
  default = null
}

variable "register_internal" {
  description = "Register in the private namespace, for callers inside the VPC."
  type        = bool
  default     = false
}

variable "namespace_id" {
  type    = string
  default = null
}

variable "namespace_name" {
  type    = string
  default = "forge-central.internal"
}

variable "task_policies" {
  description = "Extra permissions for the running process, keyed by policy name. Only sprue, the delegator and OpenBao need any. Keyed rather than one nullable string because a policy usually names resources created in the same apply: with a single string, whether the policy exists depends on knowing what is in it, and Terraform cannot count instances it has to wait until apply to evaluate."
  type        = map(string)
  default     = {}
}

variable "desired_count" {
  description = "Above 1, concurrent starts race on the goose migration lock. Set the service's *_SKIP_MIGRATIONS before raising it."
  type        = number
  default     = 1
}

variable "cpu" {
  type    = number
  default = 512
}

variable "memory" {
  type    = number
  default = 1024
}

variable "cpu_architecture" {
  description = "All six service images publish linux/arm64 as well as amd64, and Graviton Fargate is cheaper."
  type        = string
  default     = "ARM64"
}

variable "log_retention_days" {
  type    = number
  default = 30
}
