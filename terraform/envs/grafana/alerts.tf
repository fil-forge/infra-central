# Grafana alert rules for Forge, in their own folder. folders.tf sets out why
# these are git only where the dashboards beside them are not.
#
# Six rules, in three groups so each can evaluate at the interval its source and
# its ticket need: CloudWatch publishes once a minute, the appliance host
# exporter is scraped once a minute but nothing reading it needs that
# resolution, and the container rule has a ten-minute deadline in FIL-1163's
# acceptance criteria that a five-minute interval cannot meet.
#
# Three of the six came from rules built by hand in the UI and exported; the
# shapes below follow that export rather than the provider's documentation,
# which is why the expression stages address __expr__ and put their own refId in
# the condition's query.params. The other three -- FIL-1209's disk rule,
# FIL-1151's Lambda rule and FIL-1163's container rule -- follow that same shape
# rather than the provider documentation, deliberately.
#
# Of the seven alerts under FIL-1145 only FIL-1209 states a threshold. The rest
# say "too high", or defer to an SLO that has not been written (FIL-1242), or
# ask for a decision the team has not taken (FIL-1211, FIL-1212); they are
# listed at the end of this file rather than guessed at.
#
# Routing is deliberately not managed here. Every rule carries team = "forge",
# and the notification policy tree in the UI is what turns that label into a
# channel. grafana_notification_policy manages the entire tree as one resource,
# so adopting it would mean Terraform owning FilOne's routes as well as ours; and
# grafana_contact_point keeps its Slack token or webhook as an ordinary
# attribute, which would put a secret in this state for the same reason
# docs/decisions/2026-09-grafana-telemetry.md keeps the Firehoses out of the
# stage roots. rule.notification_settings would bypass the policy per rule, but
# it needs the alertingSimplifiedRouting feature flag and it hides the routing
# from whoever maintains the tree.
#
# So: add one route in the UI matching team = "forge" to whichever channel
# FIL-1164 settles on, and every rule added here after that is routed already.

variable "alert_stages" {
  description = "Stages the rules alert on, as they appear in the appliance label's <stage>-<region> prefix and in Central's fc-<stage> cluster and target group names. Every ticket says production only; terraform.tfvars holds staging until production exists (FIL-1147, FIL-808), because that is what the hand-built rules these replace were watching."
  type        = list(string)
  default     = ["prod"]
}

variable "prometheus_datasource_uid" {
  description = "UID of the grafanacloud-prom data source. Alert rules address a data source by uid where a dashboard can use its name. It is in the URL of the data source's settings page, and it is not a secret."
  type        = string
}

locals {
  stages = join("|", var.alert_stages)

  # The appliance label is <stage>-<region>, so one regex covers every region of
  # every alerting stage and a new region needs no edit here. That is FIL-1207's
  # "templated by node label so a new region needs no Grafana edit", done in
  # Terraform because a Grafana alert rule has no template variables.
  appliance_matcher = "appliance=~\"(${local.stages})-.*\", service_name=~\"appliance-.*-host\""

  # The load balancer publishes each metric three times: once per availability
  # zone, once per target group and once for the whole balancer. The two extra
  # matchers keep the per-target-group series only, as infra-central's
  # docs/observability.md sets out.
  elb_matcher = "dimension_LoadBalancer=~\"app/fc-(${local.stages})/.*\", dimension_AvailabilityZone=\"\", dimension_TargetGroup!=\"\""

  # Non-capturing group on the stage so $1 stays the service name. RE2 supports
  # (?:...) -- google/re2 doc/syntax.txt lists it as "non-capturing group" -- so
  # this parses in a Prometheus label matcher and in label_replace.
  target_group_regex = "targetgroup/fc-(?:${local.stages})-(.*)/.*"

  # The stage, captured from the same target group name. It is its own label so
  # the Central rules can group by it: without it, a rule watching more than one
  # stage sums their series together, which can cross a threshold neither stage
  # crosses alone and leaves the alert unable to say which stage it means.
  target_group_stage_regex = "targetgroup/fc-(${local.stages})-.*"

  # The same filesystem filter the dashboards use. FIL-1209 names the control and
  # data volumes; their mountpoints differ between the EC2 nodes and the
  # Servers.com host, so the rule covers every real filesystem instead, which is
  # a superset and needs no per-node edit.
  filesystem_matcher = "${local.appliance_matcher}, fstype!~\"tmpfs|vfat|squashfs|overlay\", mountpoint!~\"/boot.*\""

  # The four containers FIL-1163 names. cAdvisor labels them with the same
  # service_name the host metrics carry, so the appliance's own containers are
  # selected the same way -- which matters on the Servers.com host, where
  # cAdvisor also reports Lotus, Sophon and everything else the box runs.
  #
  # Compose service names, per infra-nodes' nodes/<node>/apps and platform
  # projects. A service added there and not added here is not watched.
  #
  # Prometheus anchors the whole regex, which is what keeps postgres-init out:
  # it is a one-shot init container that exits on every deploy, so matching it
  # would fire this rule permanently.
  container_matcher = "service_name=~\"appliance-(${local.stages})-.*-(piri|ingot|postgres|openbao)\""

  # Fields every Prometheus query stage carries. `instant` picks one sample per
  # series and needs no reduce before the threshold; a range query does.
  query_defaults = {
    editorMode    = "code"
    exemplar      = false
    intervalMs    = 60000
    maxDataPoints = 43200
    legendFormat  = "__auto"
  }
}

resource "grafana_rule_group" "central" {
  name             = "Forge Central"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 60

  # No healthy host behind a target group. `for` is 5m rather than the immediate
  # firing the hand-built rule had: this reads a CloudWatch metric published once
  # a minute with late and occasionally missing samples, so a single evaluation
  # is not evidence of anything.
  rule {
    name           = "Service has no healthy hosts"
    condition      = "B"
    for            = "5m"
    no_data_state  = "NoData"
    exec_err_state = "Error"

    annotations = {
      summary          = "{{ $labels.service }} has no healthy hosts behind its target group on {{ $labels.stage }}"
      __dashboardUid__ = "forge-central"
      __panelId__      = "6"
    }

    labels = {
      team      = "forge"
      component = "central"
      severity  = "critical"
    }

    data {
      ref_id         = "A"
      datasource_uid = var.prometheus_datasource_uid

      relative_time_range {
        from = 3600
        to   = 0
      }

      model = jsonencode(merge(local.query_defaults, {
        refId   = "A"
        instant = true
        range   = false
        expr    = <<-PROMQL
          min by (stage, service) (
            label_replace(
              label_replace(
                aws_applicationelb_healthy_host_count_minimum{${local.elb_matcher}},
                "service", "$1", "dimension_TargetGroup", "${local.target_group_regex}"
              ),
              "stage", "$1", "dimension_TargetGroup", "${local.target_group_stage_regex}"
            )
          )
        PROMQL
      }))
    }

    data {
      ref_id         = "B"
      query_type     = "expression"
      datasource_uid = "__expr__"

      relative_time_range {
        from = 0
        to   = 0
      }

      model = jsonencode({
        refId         = "B"
        type          = "threshold"
        expression    = "A"
        datasource    = { type = "__expr__", uid = "__expr__" }
        intervalMs    = 1000
        maxDataPoints = 43200
        conditions = [{
          type      = "query"
          operator  = { type = "and" }
          query     = { params = ["B"] }
          reducer   = { type = "last", params = [] }
          evaluator = { type = "lt", params = [1] }
        }]
      })
    }
  }

  # 5xx per minute, averaged over five. no_data_state is OK and that is
  # load-bearing: CloudWatch publishes a 5xx count only in minutes when a service
  # returned one, so an empty result is the healthy state rather than a gap.
  rule {
    name           = "Service 5xx errors"
    condition      = "C"
    for            = "10m"
    no_data_state  = "OK"
    exec_err_state = "Alerting"

    annotations = {
      summary          = "{{ $labels.service }} on {{ $labels.stage }} is returning more than 1 server error a minute"
      description      = "More than one 5xx per minute, averaged over five, for ten minutes."
      __dashboardUid__ = "forge-central"
      __panelId__      = "3"
    }

    labels = {
      team      = "forge"
      component = "central"
      severity  = "warning"
    }

    data {
      ref_id         = "A"
      datasource_uid = var.prometheus_datasource_uid

      relative_time_range {
        from = 3600
        to   = 0
      }

      model = jsonencode(merge(local.query_defaults, {
        refId   = "A"
        instant = false
        range   = true
        expr    = <<-PROMQL
          sum by (stage, service) (
            label_replace(
              label_replace(
                sum_over_time(
                  aws_applicationelb_httpcode_target_5_xx_count_sum{${local.elb_matcher}}[5m]
                ),
                "service", "$1", "dimension_TargetGroup", "${local.target_group_regex}"
              ),
              "stage", "$1", "dimension_TargetGroup", "${local.target_group_stage_regex}"
            )
          ) / 5
        PROMQL
      }))
    }

    data {
      ref_id         = "B"
      query_type     = "expression"
      datasource_uid = "__expr__"

      relative_time_range {
        from = 0
        to   = 0
      }

      model = jsonencode({
        refId         = "B"
        type          = "reduce"
        expression    = "A"
        reducer       = "last"
        datasource    = { type = "__expr__", uid = "__expr__" }
        intervalMs    = 1000
        maxDataPoints = 43200
      })
    }

    data {
      ref_id         = "C"
      query_type     = "expression"
      datasource_uid = "__expr__"

      relative_time_range {
        from = 0
        to   = 0
      }

      model = jsonencode({
        refId         = "C"
        type          = "threshold"
        expression    = "B"
        datasource    = { type = "__expr__", uid = "__expr__" }
        intervalMs    = 1000
        maxDataPoints = 43200
        conditions = [{
          type      = "query"
          operator  = { type = "and" }
          query     = { params = ["C"] }
          reducer   = { type = "last", params = [] }
          evaluator = { type = "gt", params = [1] }
        }]
      })
    }
  }

  # FIL-1151: "provision Lambda errors ... Define Grafana alert rules on them".
  #
  # The Lambda namespace is not in this repository's metric stream. It arrives
  # through fil-one/infra's stream, which names AWS/Lambda for the whole account
  # -- docs/decisions/2026-09-grafana-telemetry.md says why Forge Central's
  # stream deliberately does not. So this rule depends on that stream keeping
  # the namespace, and goes blind rather than wrong if it stops.
  #
  # CloudWatch publishes an error count only in minutes where the function
  # errored, so an empty result is zero errors and each sample is one minute's
  # count. sum_over_time adds them; gt 0 is the threshold because the ticket
  # names no number and any provisioning error is worth a look.
  #
  # severity warning, not critical: a failed provision does not take serving
  # traffic down. Chosen, not specified.
  rule {
    name           = "Provision Lambda errors"
    condition      = "B"
    for            = "0m"
    no_data_state  = "OK"
    exec_err_state = "Error"

    annotations = {
      summary     = "{{ $labels.dimension_FunctionName }} returned errors in the last five minutes"
      description = "The provision Lambda is erroring. Its log group is /aws/lambda/{{ $labels.dimension_FunctionName }}; docs/observability.md says how to read it in Grafana."
    }

    labels = {
      team      = "forge"
      component = "central"
      severity  = "warning"
    }

    data {
      ref_id         = "A"
      datasource_uid = var.prometheus_datasource_uid

      relative_time_range {
        from = 600
        to   = 0
      }

      model = jsonencode(merge(local.query_defaults, {
        refId        = "A"
        instant      = true
        range        = false
        intervalMs   = 1000
        legendFormat = "{{dimension_FunctionName}}"
        expr         = <<-PROMQL
          sum by (dimension_FunctionName) (
            sum_over_time(
              aws_lambda_errors_sum{dimension_FunctionName=~"fc-(${local.stages})-provision"}[5m]
            )
          )
        PROMQL
      }))
    }

    data {
      ref_id         = "B"
      query_type     = "expression"
      datasource_uid = "__expr__"

      relative_time_range {
        from = 0
        to   = 0
      }

      model = jsonencode({
        refId         = "B"
        type          = "threshold"
        expression    = "A"
        datasource    = { type = "__expr__", uid = "__expr__" }
        intervalMs    = 1000
        maxDataPoints = 43200
        conditions = [{
          type      = "query"
          operator  = { type = "and" }
          query     = { params = ["B"] }
          reducer   = { type = "last", params = [] }
          evaluator = { type = "gt", params = [0] }
        }]
      })
    }
  }
}

resource "grafana_rule_group" "appliance" {
  name             = "Forge appliances"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 300

  # Two failures, not one, and they need different queries.
  #
  # The timer stops but the box stays up. This is the common one, and the
  # absence shape misses it completely: deploy_last_success_timestamp is a
  # textfile-collector gauge (infra-nodes scripts/host/lib.sh), so node_exporter
  # re-exports it from the stamp file on every scrape whether or not the timer
  # ran. The series stays present and only its *value* goes stale, so
  # present_over_time never lapses. The age is the signal, and it is the
  # repository's own documented one -- infra-nodes docs/observability.md gives
  # `time() - deploy_last_success_timestamp{project="reconcile"} > 15 * 60`, and
  # the Regions dashboard's "Time since last deploy" panel draws exactly that
  # against a 15-minute threshold line.
  #
  # The node goes away entirely. Then there is no series to take an age of, the
  # left side returns nothing, and no_data_state = OK would keep the rule quiet
  # about a node that has vanished. So the absence shape is kept as the second
  # branch of an `or`: reported some time in the last day, not in the last
  # fifteen minutes. Its 24h window is what makes it self-cleaning, since a node
  # decommissioned longer ago than that falls out of both sides on its own.
  #
  # Either branch produces a value greater than zero -- an age in seconds, or 1
  # -- so the threshold stage stays `gt 0` and does not care which fired.
  rule {
    name           = "Appliance has stopped reporting"
    condition      = "C"
    for            = "10m"
    no_data_state  = "OK"
    exec_err_state = "Alerting"

    annotations = {
      summary          = "{{ $labels.region }} ({{ $labels.node }}) has stopped reporting"
      description      = "The reconcile stamp is more than fifteen minutes old, or the node has stopped reporting altogether. The timer runs every five, so either the node has stopped reconciling or its telemetry has stopped arriving."
      runbook_url      = "https://github.com/fil-forge/infra-nodes/blob/main/docs/RUNBOOK.md#when-something-is-wrong"
      __dashboardUid__ = "forge-regions"
      __panelId__      = "13"
    }

    labels = {
      team      = "forge"
      component = "appliance"
      severity  = "critical"
    }

    data {
      ref_id         = "A"
      datasource_uid = var.prometheus_datasource_uid

      relative_time_range {
        from = 3600
        to   = 0
      }

      model = jsonencode(merge(local.query_defaults, {
        refId        = "A"
        instant      = false
        range        = true
        legendFormat = "{{appliance}}"
        expr         = <<-PROMQL
          (
            max by (node, region, appliance) (
              time() - deploy_last_success_timestamp{project="reconcile", ${local.appliance_matcher}}
            ) > 900
          )
          or
          (
            max by (node, region, appliance) (
              present_over_time(deploy_last_success_timestamp{project="reconcile", ${local.appliance_matcher}}[24h])
            )
            unless
            max by (node, region, appliance) (
              present_over_time(deploy_last_success_timestamp{project="reconcile", ${local.appliance_matcher}}[15m])
            )
          )
        PROMQL
      }))
    }

    data {
      ref_id         = "B"
      query_type     = "expression"
      datasource_uid = "__expr__"

      relative_time_range {
        from = 0
        to   = 0
      }

      model = jsonencode({
        refId         = "B"
        type          = "reduce"
        expression    = "A"
        reducer       = "last"
        datasource    = { type = "__expr__", uid = "__expr__" }
        intervalMs    = 1000
        maxDataPoints = 43200
      })
    }

    data {
      ref_id         = "C"
      query_type     = "expression"
      datasource_uid = "__expr__"

      relative_time_range {
        from = 0
        to   = 0
      }

      model = jsonencode({
        refId         = "C"
        type          = "threshold"
        expression    = "B"
        datasource    = { type = "__expr__", uid = "__expr__" }
        intervalMs    = 1000
        maxDataPoints = 43200
        conditions = [{
          type      = "query"
          operator  = { type = "and" }
          query     = { params = ["C"] }
          reducer   = { type = "last", params = [] }
          evaluator = { type = "gt", params = [0] }
        }]
      })
    }
  }

  # FIL-1209: "Create an alert when remaining free space drops below 40% of the
  # total volume size."
  #
  # Grouped by node as well as region: two boxes in one stage and region share
  # service_name and are told apart by node. An instant query, so no reduce stage.
  #
  # for = 15m is chosen, not specified: a filesystem crossing 40% is not an event
  # that needs a one-minute response.
  rule {
    name           = "Appliance free disk space below 40%"
    condition      = "B"
    for            = "15m"
    no_data_state  = "NoData"
    exec_err_state = "Error"

    annotations = {
      summary          = "{{ $labels.appliance }} has less than 40% free on {{ $labels.mountpoint }}"
      description      = "{{ $labels.node }} is below 40% free on {{ $labels.mountpoint }}. Volumes and their sizes are in infra-nodes' terraform/modules/node."
      runbook_url      = "https://github.com/fil-forge/infra-nodes/blob/main/docs/RUNBOOK.md#when-something-is-wrong"
      __dashboardUid__ = "forge-regions"
      __panelId__      = "8"
    }

    labels = {
      team      = "forge"
      component = "appliance"
      severity  = "warning"
    }

    data {
      ref_id         = "A"
      datasource_uid = var.prometheus_datasource_uid

      relative_time_range {
        from = 600
        to   = 0
      }

      model = jsonencode(merge(local.query_defaults, {
        refId      = "A"
        instant    = true
        range      = false
        intervalMs = 1000
        expr       = <<-PROMQL
          min by (appliance, region, node, mountpoint) (
            node_filesystem_avail_bytes{${local.filesystem_matcher}}
            / node_filesystem_size_bytes{${local.filesystem_matcher}}
          )
        PROMQL
      }))
    }

    data {
      ref_id         = "B"
      query_type     = "expression"
      datasource_uid = "__expr__"

      relative_time_range {
        from = 0
        to   = 0
      }

      model = jsonencode({
        refId         = "B"
        type          = "threshold"
        expression    = "A"
        datasource    = { type = "__expr__", uid = "__expr__" }
        intervalMs    = 1000
        maxDataPoints = 43200
        conditions = [{
          type      = "query"
          operator  = { type = "and" }
          query     = { params = ["B"] }
          reducer   = { type = "last", params = [] }
          evaluator = { type = "lt", params = [0.4] }
        }]
      })
    }
  }
}

# FIL-1163's acceptance criteria are the only ones under FIL-1145 that name a
# response time: "Stopping the Ingot container on staging produces a Slack alert
# from Grafana within ten minutes", and "Recovery clears the alert."
#
# Its own group, at 60s, because the 300s the other appliance rules run at
# cannot meet that. Worst case here is one scrape gap (cAdvisor scrapes every
# fifteen seconds), the 5m absence window and one evaluation: about six minutes.
# At 300s it would be about eleven, which fails the criterion on paper.
resource "grafana_rule_group" "appliance_containers" {
  name             = "Forge appliance containers"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 60

  # Same present_over_time/unless shape as "Appliance has stopped reporting", and
  # for the same reason: cAdvisor stops publishing a container's series when the
  # container goes away, so the signal is absence, and absence cannot be compared
  # against a threshold directly. The 24h left side makes it self-cleaning -- a
  # service removed from the Compose project falls out of both sides and stops
  # alerting with no edit here. It also means a container that has been down
  # longer than a day stops alerting, which is the same trade the node rule makes.
  #
  # Recovery clears it as soon as one sample lands in the 5m window, which
  # satisfies the second criterion.
  #
  # Only staging ships this: cAdvisor runs on the Servers.com host and not on the
  # dev EC2 node, where the Alloy container has no cgroup mount
  # (infra-nodes/docs/observability.md). On a stage with no cAdvisor the query
  # returns nothing and the rule is silent rather than firing for every
  # container, because the left side is absent too.
  #
  # The `and on (node)` is what keeps a telemetry outage from reading as an
  # outage. cAdvisor never having run is the harmless case above; cAdvisor
  # having run and then stopped is not. If the scrape or its Alloy pipeline dies
  # after a container has reported, the 24h side stays present while the 5m side
  # empties, and without the gate every watched container on that node pages at
  # once. `no_data_state = "OK"` does not help: the query still returns the
  # stale 24h series, so it is data, not no-data. The gate requires cAdvisor to
  # have reported *something* on that node in the same five minutes, which is a
  # far wider net than the four watched services -- cAdvisor reports the host's
  # other containers too, Lotus and Sophon among them, all under job="cadvisor"
  # (infra-nodes/docs/observability.md). So it stays true while cAdvisor lives,
  # even with all four watched containers down, and goes false the moment the
  # scrape does, suppressing the rule for that node rather than paging for it.
  #
  # What that trades away: a node whose cAdvisor dies is no longer watched by
  # this rule, and nothing here says so. "Appliance has stopped reporting"
  # covers a node that goes silent entirely, but it reads the deploy stamp, not
  # cAdvisor, so a live node with a dead cAdvisor is a blind spot. Closing it
  # needs a rule on the scrape's own health, which is FIL-1163 territory once
  # somebody decides what to do about it.
  rule {
    name           = "Appliance container is not running"
    condition      = "C"
    for            = "0m"
    no_data_state  = "OK"
    exec_err_state = "Alerting"

    annotations = {
      summary          = "{{ $labels.service_name }} is not running on {{ $labels.node }}"
      description      = "cAdvisor reported this container within the last day and not within the last five minutes, so it has stopped. Container logs: {service_name=\"{{ $labels.service_name }}\"}."
      runbook_url      = "https://github.com/fil-forge/infra-nodes/blob/main/docs/RUNBOOK.md#when-something-is-wrong"
      __dashboardUid__ = "forge-regions"
      __panelId__      = "1"
    }

    labels = {
      team      = "forge"
      component = "appliance"
      severity  = "critical"
    }

    data {
      ref_id         = "A"
      datasource_uid = var.prometheus_datasource_uid

      relative_time_range {
        from = 86400
        to   = 0
      }

      model = jsonencode(merge(local.query_defaults, {
        refId        = "A"
        instant      = false
        range        = true
        legendFormat = "{{service_name}}"
        expr         = <<-PROMQL
          (
            max by (node, region, appliance, service_name) (
              present_over_time(container_cpu_usage_seconds_total{${local.container_matcher}}[24h])
            )
            unless
            max by (node, region, appliance, service_name) (
              present_over_time(container_cpu_usage_seconds_total{${local.container_matcher}}[5m])
            )
          )
          and on (node)
          max by (node) (
            present_over_time(container_cpu_usage_seconds_total{job="cadvisor"}[5m])
          )
        PROMQL
      }))
    }

    data {
      ref_id         = "B"
      query_type     = "expression"
      datasource_uid = "__expr__"

      relative_time_range {
        from = 0
        to   = 0
      }

      model = jsonencode({
        refId         = "B"
        type          = "reduce"
        expression    = "A"
        reducer       = "last"
        datasource    = { type = "__expr__", uid = "__expr__" }
        intervalMs    = 1000
        maxDataPoints = 43200
      })
    }

    data {
      ref_id         = "C"
      query_type     = "expression"
      datasource_uid = "__expr__"

      relative_time_range {
        from = 0
        to   = 0
      }

      model = jsonencode({
        refId         = "C"
        type          = "threshold"
        expression    = "B"
        datasource    = { type = "__expr__", uid = "__expr__" }
        intervalMs    = 1000
        maxDataPoints = 43200
        conditions = [{
          type      = "query"
          operator  = { type = "and" }
          query     = { params = ["C"] }
          reducer   = { type = "last", params = [] }
          evaluator = { type = "gt", params = [0] }
        }]
      })
    }
  }
}

# Not written, and why. Each needs a number or a decision that is not in the
# ticket, and inventing one would page someone against a threshold nobody agreed:
#
#   FIL-1207  5xx error rate.      The "Service 5xx errors" rule above is a
#                                  count, not the rate FIL-1207 asks for. The
#                                  availability target it wants is FIL-1242,
#                                  which is in the backlog, and its acceptance
#                                  criteria defer the channel to FIL-1164.
#   FIL-1210  TTFB.                Threshold is explicitly "comes from the SLO
#                                  definition in FIL-1242". R1.6.
#   FIL-1213  TTLB.                Same, and needs PutObject, GetObject and
#                                  CompleteMultipartUpload excluded, which Caddy
#                                  can only approximate by method.
#   FIL-1211  Request rate anomaly. "Decide with the team whether we want an
#                                  alert." Not decided.
#   FIL-1212  Ingress/egress.      Same. Not decided.
#   FIL-1214  CPU and memory.      "Propose the thresholds and discuss them with
#                                  the team." Not proposed.
#
# Two more are blocked on a metric rather than a number:
#
#   FIL-1163  TLS certificate      No metric carries it. Caddy 2.9.1 exports
#             expiry.              seven caddy_http_* series and none is a
#                                  certificate expiry
#                                  (caddyserver/caddy modules/caddyhttp/metrics.go
#                                  at v2.9.1); certificate activity is legible in
#                                  Caddy's runtime log only. The usual source is
#                                  a blackbox exporter publishing
#                                  probe_ssl_earliest_cert_expiry, which means an
#                                  Alloy config change on the staging host --
#                                  whose Alloy config lives outside infra-nodes.
#                                  The other three FIL-1163 bullets are covered:
#                                  the deploy stamp by "Appliance has stopped
#                                  reporting", the containers by the group above,
#                                  and Caddy 5xx by FIL-1207's rule once it has a
#                                  threshold.
#
#   FIL-1151  ECS running count    AWS/ECS publishes CPUUtilization and
#             below desired.       MemoryUtilization; RunningTaskCount is a
#                                  Container Insights metric, in the
#                                  ECS/ContainerInsights namespace, which no
#                                  stream in this account ships. A crash-looping
#                                  task with an ALB route is already caught by
#                                  "Service has no healthy hosts"; one without a
#                                  route (hostname == null in
#                                  modules/shared/ecs-service) is not caught by
#                                  anything. Enabling Container Insights on the
#                                  cluster and adding the namespace to
#                                  modules/telemetry would close that gap.
