variable "stages" {
  description = "Stages in this account and region, one log Firehose each. Take it from the constants module so the list agrees with the CI roles' state grants."
  type        = list(string)

  validation {
    condition     = length(var.stages) > 0
    error_message = "stages must name at least one stage; a module with no log Firehose ships metrics and nothing else, which is never what a caller meant."
  }
}

# The two instance ids and the token are in 1Password: vault "Fil One", item
# "Forge Central", section GRAFANA. The README's bootstrap section has the
# `op read` lines that export them as TF_VAR_* for an apply.
#
# The URL defaults name the filecoinfoundation stack, the same one fil-one/infra
# and infra-nodes ship to. The 1Password item carries the stack's ordinary push
# URLs; Grafana's Firehose endpoints are derived from those by swapping the host
# prefix, `logs-prod3` to `aws-logs-prod3` and `prometheus-prod-10` to
# `aws-metric-streams-prod-10`, which is what the defaults below hold.

variable "grafana_logs_url" {
  description = "Grafana Cloud's Firehose endpoint for logs."
  type        = string
  default     = "https://aws-logs-prod3.grafana.net/aws-logs/api/v1/push"
}

variable "grafana_logs_user" {
  description = "Loki instance id of the Grafana Cloud stack. GRAFANA_LOGS_USER in the 1Password item."
  type        = string
}

variable "grafana_metrics_url" {
  description = "Grafana Cloud's Firehose endpoint for metric streams."
  type        = string
  default     = "https://aws-metric-streams-prod-10.grafana.net/aws-metrics/api/v1/push"
}

variable "grafana_metrics_user" {
  description = "Prometheus instance id of the Grafana Cloud stack. GRAFANA_METRICS_USER in the 1Password item, and different from the Loki one."
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
  description = "Grafana Cloud access policy token with the logs:write and metrics:write scopes. GRAFANA_CLOUD_PUSH_TOKEN in the 1Password item; pass it as TF_VAR_grafana_push_token and never commit it."
  type        = string
  sensitive   = true
}
