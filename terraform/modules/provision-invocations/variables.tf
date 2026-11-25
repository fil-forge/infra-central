variable "stages" {
  description = "Stages in this account and region, one provision Lambda each. Take it from the constants module, as the telemetry module does."
  type        = list(string)

  validation {
    condition     = length(var.stages) > 0
    error_message = "stages must name at least one stage; a trail with no function to select logs nothing."
  }

  validation {
    condition     = length(distinct(var.stages)) == length(var.stages)
    error_message = "stages must not repeat a name; each stage gets exactly one rule and log group."
  }
}

variable "log_firehose_arns" {
  description = "Stage to the ARN of its log Firehose, from the telemetry module in the same root."
  type        = map(string)

  validation {
    condition     = alltrue([for stage in var.stages : contains(keys(var.log_firehose_arns), stage)])
    error_message = "log_firehose_arns must have an entry for every stage, or that stage's invocations never reach Grafana."
  }
}
