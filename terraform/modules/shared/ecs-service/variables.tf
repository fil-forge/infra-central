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

    Use secret_files_base64 for a value whose bytes are not text.

    A key is a shell identifier: letters, digits and underscore, starting with
    a letter or underscore. A filename is a plain basename: letters, digits,
    dot, underscore and hyphen, starting with a letter or digit. Both end up
    inside the wrapper's shell string, so nothing else is accepted.
  EOT
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for env_var in keys(var.secret_files) : contains(keys(var.secrets), env_var)])
    error_message = "Every secret_files key must also be a secrets key: the wrapper writes an environment variable to a file, so ECS has to inject it first. A missing entry writes an empty file and the service fails at startup with an unhelpful parse error."
  }

  validation {
    condition     = alltrue([for env_var in keys(var.secret_files) : can(regex("^[A-Za-z_][A-Za-z0-9_]*$", env_var))])
    error_message = "Every secret_files key must be a shell identifier matching ^[A-Za-z_][A-Za-z0-9_]*$. The wrapper reads it as \"$NAME\" inside a /bin/sh -c command line, so a hyphen, a space or a quote would expand to the wrong value or break the command."
  }

  validation {
    condition     = alltrue([for filename in values(var.secret_files) : can(regex("^[A-Za-z0-9][A-Za-z0-9._-]*$", filename))])
    error_message = "Every secret_files value must be a plain basename matching ^[A-Za-z0-9][A-Za-z0-9._-]*$. The wrapper interpolates it into a /bin/sh -c command line, so a slash, a space or a shell metacharacter would escape the secret directory or break the command."
  }
}

variable "secret_files_base64" {
  description = <<-EOT
    As secret_files, for a parameter stored base64-encoded: the wrapper decodes
    it on the way to the file.

    This is how a binary secret travels at all. ECS injects every secret as an
    environment variable, and an environment variable cannot hold a NUL byte:
    runc refuses to create the container and reports only the variable's name.
    The delegator's two UCAN proofs are bare DAG-CBOR, so they take this path.

    Keys and filenames follow the same rules as secret_files.
  EOT
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for env_var in keys(var.secret_files_base64) : contains(keys(var.secrets), env_var)])
    error_message = "Every secret_files_base64 key must also be a secrets key: the wrapper writes an environment variable to a file, so ECS has to inject it first. A missing entry writes an empty file and the service fails at startup with an unhelpful parse error."
  }

  validation {
    condition     = alltrue([for env_var in keys(var.secret_files_base64) : can(regex("^[A-Za-z_][A-Za-z0-9_]*$", env_var))])
    error_message = "Every secret_files_base64 key must be a shell identifier matching ^[A-Za-z_][A-Za-z0-9_]*$. The wrapper reads it as \"$NAME\" inside a /bin/sh -c command line, so a hyphen, a space or a quote would expand to the wrong value or break the command."
  }

  validation {
    condition     = alltrue([for filename in values(var.secret_files_base64) : can(regex("^[A-Za-z0-9][A-Za-z0-9._-]*$", filename))])
    error_message = "Every secret_files_base64 value must be a plain basename matching ^[A-Za-z0-9][A-Za-z0-9._-]*$. The wrapper interpolates it into a /bin/sh -c command line, so a slash, a space or a shell metacharacter would escape the secret directory or break the command."
  }
}

variable "shell_command" {
  description = "Command to exec, as a shell string. Required when either secret_files variable is set, because the wrapper replaces the image's entrypoint. Null uses the image's own entrypoint and command."
  type        = string
  default     = null

  validation {
    condition     = (length(var.secret_files) + length(var.secret_files_base64)) == 0 || var.shell_command != null
    error_message = "Writing a secret to a file replaces the image entrypoint with a wrapper, so shell_command must say what to exec afterwards."
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
  description = "Public hostname. Null gives the service no ALB route and no public DNS, leaving it reachable over the private namespace alone. Setting it requires listener_arn, listener_priority, route53_zone_id, alb_dns_name and alb_zone_id."
  type        = string
  default     = null

  validation {
    condition = var.hostname == null || alltrue([
      var.listener_arn != null,
      var.listener_priority != null,
      var.route53_zone_id != null,
      var.alb_dns_name != null,
      var.alb_zone_id != null,
    ])
    error_message = "hostname creates an ALB listener rule and a Route53 alias record, so listener_arn, listener_priority, route53_zone_id, alb_dns_name and alb_zone_id must all be set with it. Left null, the provider rejects them at apply with an error that does not name the missing input."
  }
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

variable "tmp_size_mib" {
  description = <<-EOT
    Size of the /tmp tmpfs, the container's only writable path. The default
    covers what the entrypoint wrapper puts there — a few identity keys, the
    delegator's two proofs, OpenBao's rendered config — which together are
    kilobytes.

    Raise it for a service that needs real scratch space. Note the failure is
    not always at startup: a service that buffers to /tmp under load hits
    ENOSPC when it fills, not when it boots. tmpfs pages count against the
    task's memory limit as they are used, not when the mount is created, so
    the cap is what a runaway writer hits rather than a reservation.
  EOT
  type        = number
  default     = 10
}
