variable "stages" {
  description = "Stages in this account and region, one log Firehose each. Take it from the constants module so the list agrees with the CI roles' state grants."
  type        = list(string)

  validation {
    condition     = length(var.stages) > 0
    error_message = "stages must name at least one stage; a module with no log Firehose ships metrics and nothing else, which is never what a caller meant."
  }
}

# The two push URLs and two instance ids are on the Grafana Cloud stack's
# details page, on the Loki and Prometheus tiles. The URL defaults name the
# filecoinfoundation stack, the same one fil-one/infra and infra-nodes ship to.
# Grafana's Firehose endpoints are derived from the stack's ordinary push URLs
# by swapping the host prefix: `logs-prod3` becomes `aws-logs-prod3`,
# `prometheus-prod-10` becomes `aws-metric-streams-prod-10`.

variable "grafana_logs_url" {
  description = "Grafana Cloud's Firehose endpoint for logs."
  type        = string
  default     = "https://aws-logs-prod3.grafana.net/aws-logs/api/v1/push"
}

variable "grafana_logs_user" {
  description = "Loki instance id of the Grafana Cloud stack. The numeric user on the stack's Loki tile."
  type        = string
}

variable "grafana_metrics_url" {
  description = "Grafana Cloud's Firehose endpoint for metric streams."
  type        = string
  default     = "https://aws-metric-streams-prod-10.grafana.net/aws-metrics/api/v1/push"
}

variable "grafana_metrics_user" {
  description = "Prometheus instance id of the Grafana Cloud stack. The numeric user on the stack's Prometheus tile, and different from the Loki one."
  type        = string
}

# One token for both signals, as infra-nodes does. Firehose sends
# `<instance id>:<token>` in X-Amz-Firehose-Access-Key, and Grafana routes on
# the instance id, so the same token serves Loki and Prometheus as long as its
# access policy carries both scopes.
#
# Stored in this root's state. That is the reason the module is in a bootstrap
# root and not a stage root: see the header of main.tf.
variable "grafana_push_token" {
  description = "Grafana Cloud access policy token with the logs:write and metrics:write scopes. Pass it as TF_VAR_grafana_push_token; never commit it."
  type        = string
  sensitive   = true
}
