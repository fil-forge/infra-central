# Grafana alert rules for Forge, in their own folder. folders.tf sets out why
# these are git only where the dashboards beside them are not.
#
# Writing a rule needs more on forge-terraform than folder Admin. Each of these
# is necessary and none is sufficient alone:
#
#   - `alert.provisioning.provenance:write`, carried by the fixed role
#     `fixed:alerting.provisioning.provenance:writer` and shown in the UI as
#     "Alerting:Set provisioning status". Unscoped. It satisfies the routing
#     middleware, which demands a permission no folder grant can confer
#     (ngalert/api/authorization.go, the PUT rule-groups case).
#
#   - `datasources:query` on every data source the group's rules read, granted
#     on each data source's own Permissions tab rather than through a role. Once
#     past the middleware the handler checks every data source the rules read
#     (ngalert/accesscontrol/rules.go, getRulesQueryEvaluator), and a group with
#     one it cannot query is refused whole, as a 403 putAlertRuleGroupForbidden.
#     So a rule on a new data source needs that grant before it merges.
#     Expression nodes are skipped, which is why the folders and dashboards in
#     this root apply without it.
#
# Routing is deliberately not managed here. Every rule carries
# team_name = "forge", and the notification policy tree in the UI is what turns
# that label into a channel. grafana_notification_policy manages the entire tree
# as one resource, so adopting it would mean Terraform owning FilOne's routes as
# well as ours; and
# grafana_contact_point keeps its Slack token or webhook as an ordinary
# attribute, which would put a secret in this state for the same reason
# docs/decisions/2026-09-grafana-telemetry.md keeps the Firehoses out of the
# stage roots. rule.notification_settings would bypass the policy per rule, but
# it needs the alertingSimplifiedRouting feature flag and it hides the routing
# from whoever maintains the tree.
#
# So: add one route in the UI matching team_name = "forge" to whichever channel
# FIL-1164 settles on, and every rule added here after that is routed already.

variable "alert_stages" {
  description = "Stages the rules alert on, as they appear in the appliance label's <stage>-<region> prefix and in Central's fc-<stage> cluster and target group names. Every ticket says production only; terraform.tfvars adds staging, which is what the hand-built rules these replace were watching."
  type        = list(string)
  default     = ["prod"]
}

variable "prometheus_datasource_uid" {
  description = "UID of the grafanacloud-prom data source. Alert rules address a data source by uid where a dashboard can use its name. It is in the URL of the data source's settings page, and it is not a secret."
  type        = string
}

variable "loki_datasource_uid" {
  description = "UID of the grafanacloud-filecoinfoundation-logs data source, the stack's Loki. Addressed by uid for the same reason as the Prometheus one. It is in the URL of the data source's settings page, and it is not a secret."
  type        = string
}

locals {
  stages = join("|", var.alert_stages)

  # The appliance label is <stage>-<region>, so one regex covers every region of
  # every alerting stage and a new region needs no edit here. Templating a rule
  # by node label is a requirement; it happens in Terraform because a Grafana
  # alert rule has no template variables of its own.
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

  # The same filesystem filter the dashboards use. What wants watching is the
  # control and data volumes, but their mountpoints differ between the EC2 nodes
  # and the Servers.com host, so this covers every real filesystem instead --
  # a superset, and one that needs no per-node edit.
  filesystem_matcher = "${local.appliance_matcher}, fstype!~\"tmpfs|vfat|squashfs|overlay\", mountpoint!~\"/boot.*\""

  # Piri's container log stream. Alloy names it appliance-<stage>-<region>-piri
  # from the Compose service and stamps appliance, region and node on it
  # (infra-nodes nodes/dev/platform/config/alloy/config.alloy), so the same
  # appliance matcher narrows it to the alerting stages.
  piri_log_matcher = "appliance=~\"(${local.stages})-.*\", service_name=~\"appliance-.*-piri\""

  # Ingot's OTLP metrics. Alloy names them appliance-<stage>-<region>-ingot
  # from Ingot's service.name and stamps appliance, region and node on them,
  # the same as Piri's (infra-nodes docs/observability.md).
  ingot_matcher = "appliance=~\"(${local.stages})-.*\", service_name=~\"appliance-.*-ingot\""

  # Postgres's container log stream, same scheme. Anchored, so this is the
  # postgres service and not postgres-init.
  postgres_log_matcher = "appliance=~\"(${local.stages})-.*\", service_name=~\"appliance-.*-postgres\""

  # Caddy's request metrics, narrowed to traffic the appliance's own sites
  # answered. caddy_http_request_duration_seconds_count is the series to read:
  # the plain request counter carries no code label at all, because Caddy
  # increments it before a status exists (caddyserver/caddy,
  # modules/caddyhttp/metrics.go -- the counter takes a label set without code,
  # the histograms take one with it).
  #
  # What is left out, and why it matters: each of these would otherwise sit in
  # the denominator of an error ratio without being traffic a site served.
  #
  #   remaining_auto_https_redirects is the :80 listener Caddy generates by
  #   itself. It only ever redirects, so it can add to the denominator and
  #   never to the numerator.
  #
  #   _other is where Caddy puts a request whose Host matches no configured
  #   site, which is junk by definition. per_host is what creates that bucket.
  #
  #   An empty host is the same traffic on the staging node, where the host's
  #   Alloy blanks the label rather than letting Caddy bucket it. Prometheus
  #   treats an empty label value as absent, so host=~".+" is what drops it.
  caddy_matcher = "appliance=~\"(${local.stages})-.*\", service_name=~\"appliance-.*-caddy\", server!=\"remaining_auto_https_redirects\", host!=\"_other\", host=~\".+\""

  # Every appliance container that is meant to stay up: all of them except the
  # one whose job is to exit.
  #
  # A deny-list, not an allow-list, so a service added to a Compose project is
  # watched from the day it ships rather than the day somebody remembers to
  # list it here. The failure modes are not symmetric -- a missing allow-list
  # entry is a container nobody is watching and nothing says so, while a wrong
  # deny-list entry is an alert naming the service it is wrong about. Loud beats
  # silent.
  #
  # `service_name` is `appliance-<stage>-<region>-<compose service>`, set by the
  # node's Alloy from the Compose service label and absent on anything started
  # by hand (infra-nodes/docs/observability.md). So the prefix already excludes
  # the host's own containers -- on the Servers.com box cAdvisor reports Lotus,
  # Sophon and the rest, none of which carries one.
  #
  # postgres-init is excluded because it is `restart: "no"`: it exits on every
  # deploy by design, and watching it would fire this rule permanently. Anything
  # else added with that policy needs excluding here too.
  container_matcher = "service_name=~\"appliance-(${local.stages})-.*\", service_name!~\".*-postgres-init\""

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

# 60s because CloudWatch publishes these metrics once a minute; evaluating
# slower would just add latency to a signal that is already a minute old.
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
      team_name = "forge"
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

    # __expr__ is Grafana's built-in server-side expression engine, addressed as
    # if it were a data source. A stage pointed at it queries nothing: it
    # transforms the stages before it, inside Grafana, after their queries have
    # returned. That is what lets one rule reduce a query to a single number and
    # then threshold it.
    #
    # Two quirks of the shape below, both unusual and both deliberate. The
    # provider's documentation shows neither; this is what Grafana's own rule
    # export produces, and what applies cleanly. Follow the rules already in
    # this file rather than the docs.
    #
    #   - `datasource_uid` and the model's nested `datasource` both carry the
    #     literal "__expr__" rather than a real uid.
    #   - a threshold stage repeats its *own* refId in
    #     `conditions[].query.params` rather than naming the stage it reads.
    #     `expression` is what actually names its input.
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
      team_name = "forge"
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

  # Any error out of the provision Lambda. The threshold is gt 0 because a
  # provisioning error is always worth a look.
  #
  # The AWS/Lambda namespace does not come from this repository's metric stream.
  # It arrives through fil-one/infra's, which names the namespace for the whole
  # account -- docs/decisions/2026-09-grafana-telemetry.md says why Forge
  # Central's stream deliberately does not. If that stream ever drops it, this
  # rule goes blind rather than wrong.
  #
  # CloudWatch publishes an error count only in minutes where the function
  # errored, so an empty result is zero errors and each sample is one minute's
  # count; sum_over_time adds them.
  #
  # warning rather than critical: a failed provision does not take serving
  # traffic down.
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
      team_name = "forge"
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

# 300s although the host exporter is scraped once a minute. Nothing in this
# group is time-critical enough to want the extra resolution, and a slower
# interval costs nothing here.
resource "grafana_rule_group" "appliance" {
  name             = "Forge Regions"
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
      team_name = "forge"
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

  # 40% of the total volume size. The one threshold in this file that was agreed
  # rather than chosen here (FIL-1209).
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
      team_name = "forge"
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

  # A stopgap for a Lotus whose head has stopped moving. Piri's chain scheduler
  # (curio lib/chainsched) ticks every five minutes and, when no head change has
  # arrived since the last tick, logs
  #
  #   no notifications received in 5m0s, resubscribing to ChainNotify
  #
  # and resubscribes. A stuck Lotus answers the new subscription with its current
  # tipset and nothing after, so the line recurs roughly every ten minutes for as
  # long as the head is stuck. Nothing else Piri exports says so: it stays up,
  # answers its health check and keeps its metrics flowing, and only its proofs
  # stop. A Lotus that is down outright fails the subscription instead, and logs
  # something else.
  #
  # Any line in fifteen minutes is a match, since with a ten-minute cadence that
  # window always holds one while the head is stuck. `for` is 15m so a single
  # line does not fire on its own: fifteen minutes of pending needs a second line
  # inside the window, which is about twenty minutes of a head that has not
  # moved. Filecoin produces a tipset every thirty seconds, so that is well past
  # anything a healthy chain does.
  #
  # no_data_state is OK for the reason the 5xx rule gives: count_over_time
  # returns a series only for a node that logged the line, so an empty result is
  # the healthy state. An instant query, so no reduce stage.
  rule {
    name           = "Piri has stopped receiving chain notifications"
    condition      = "B"
    for            = "15m"
    no_data_state  = "OK"
    exec_err_state = "Error"

    annotations = {
      summary     = "Piri on {{ $labels.node }} ({{ $labels.region }}) has stopped receiving chain head changes"
      description = "Piri's chain scheduler has logged \"no notifications received ... resubscribing to ChainNotify\" repeatedly for fifteen minutes: the Lotus it reads the chain from is up but its head is not moving, so Piri cannot schedule or submit proofs. Check the sync status of that Lotus (`lotus sync wait` or `lotus chain head` on the host that owns it) and run `piri status` in the Piri container."
      runbook_url = "https://github.com/fil-forge/infra-nodes/blob/main/docs/RUNBOOK.md#when-something-is-wrong"
    }

    labels = {
      team_name = "forge"
      component = "appliance"
      severity  = "critical"
    }

    data {
      ref_id         = "A"
      datasource_uid = var.loki_datasource_uid

      relative_time_range {
        from = 900
        to   = 0
      }

      model = jsonencode({
        refId         = "A"
        editorMode    = "code"
        queryType     = "instant"
        intervalMs    = 1000
        maxDataPoints = 43200
        expr          = <<-LOGQL
          sum by (appliance, region, node) (
            count_over_time(
              {${local.piri_log_matcher}}
                |~ "no notifications received in .* resubscribing to ChainNotify"
              [15m]
            )
          )
        LOGQL
      })
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

  # Postgres refusing connections. Seen for real in the 2026-09-24 load test:
  # staging Postgres refused 3,629 connections in 27 minutes, every multipart
  # object's CompleteMultipartUpload failed at least once, and nothing alerted.
  #
  # Postgres reports connection exhaustion in more than one wording and the
  # pattern covers them: "sorry, too many clients already" when max_connections
  # is gone, and "remaining connection slots are reserved ..." when only the
  # superuser reserve is left. The rest of that second sentence differs across
  # major versions, so the pattern stops before the part that varies.
  #
  # The signal is dense while it lasts: a rate that high puts a line in every
  # window. `for` is 5m rather than firing on one line, which is what keeps a
  # deploy out of it -- postgres-init runs and Postgres restarts on every
  # deploy, and a client that reconnects during the gap can see one refusal.
  # Five minutes of continuous refusals is not that.
  #
  # no_data_state is OK for the same reason as the rules above: count_over_time
  # returns a series only for a node that logged the line, so an empty result is
  # the healthy state. An instant query, so no reduce stage.
  rule {
    name           = "Postgres is refusing connections"
    condition      = "B"
    for            = "5m"
    no_data_state  = "OK"
    exec_err_state = "Error"

    annotations = {
      summary     = "Postgres on {{ $labels.node }} ({{ $labels.region }}) is refusing connections"
      description = "Postgres has been out of connection slots for five minutes, so requests that need the database are failing. Ingot's uploads are the first thing to break. Check what is holding connections (`SELECT count(*), state FROM pg_stat_activity GROUP BY state;`) against max_connections, and read the container log: {service_name=\"{{ $labels.service_name }}\"}."
      runbook_url = "https://github.com/fil-forge/infra-nodes/blob/main/docs/RUNBOOK.md#when-something-is-wrong"
    }

    labels = {
      team_name = "forge"
      component = "appliance"
      severity  = "critical"
    }

    data {
      ref_id         = "A"
      datasource_uid = var.loki_datasource_uid

      relative_time_range {
        from = 300
        to   = 0
      }

      model = jsonencode({
        refId         = "A"
        editorMode    = "code"
        queryType     = "instant"
        intervalMs    = 1000
        maxDataPoints = 43200
        expr          = <<-LOGQL
          sum by (appliance, region, node, service_name) (
            count_over_time(
              {${local.postgres_log_matcher}}
                |~ "too many clients already|remaining connection slots are reserved"
              [5m]
            )
          )
        LOGQL
      })
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


  # 5xx as a share of what each site answered, split by host so Piri's traffic
  # and Ingot's are judged apart -- a site serving nothing but errors would
  # otherwise be diluted by a healthy one beside it.
  #
  # The threshold is chosen, not derived: the availability target that would
  # set it is FIL-1242, which has not been written. 5% sits well above the 502s
  # a deploy produces while an upstream restarts, and `for` is 10m so a deploy
  # cannot hold it there.
  #
  # no_data_state is OK. A site with no 5xx at all produces no series on the
  # numerator's side, so the division drops it and an empty result is the
  # healthy state. An instant query, so no reduce stage.
  rule {
    name           = "Appliance 5xx rate too high"
    condition      = "B"
    for            = "10m"
    no_data_state  = "OK"
    exec_err_state = "Error"

    annotations = {
      summary     = "{{ $labels.host }} on {{ $labels.node }} is returning 5xx for more than 5% of requests"
      description = "Caddy has answered more than one request in twenty with a 5xx for ten minutes. A 502 is Caddy failing to reach the upstream, so check the container is running and healthy; a 500 came from Piri or Ingot itself, so read its log. Split by code and handler: sum by (code, handler) (rate(caddy_http_request_duration_seconds_count{host=\"{{ $labels.host }}\", code=~\"5..\"}[5m]))."
      runbook_url = "https://github.com/fil-forge/infra-nodes/blob/main/docs/RUNBOOK.md#when-something-is-wrong"
    }

    labels = {
      team_name = "forge"
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
          (
            sum by (appliance, region, node, host) (
              rate(caddy_http_request_duration_seconds_count{${local.caddy_matcher}, code=~"5.."}[5m])
            )
            /
            sum by (appliance, region, node, host) (
              rate(caddy_http_request_duration_seconds_count{${local.caddy_matcher}}[5m])
            )
          )
          # Gate on the site actually being used. Overnight a site can serve a
          # handful of requests, where one error is a large share of them; below
          # roughly thirty requests in the window the ratio says nothing. `and`
          # needs both sides to carry the same labels, which is why the grouping
          # repeats here.
          and
          sum by (appliance, region, node, host) (
            rate(caddy_http_request_duration_seconds_count{${local.caddy_matcher}}[5m])
          ) > 0.1
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
          evaluator = { type = "gt", params = [0.05] }
        }]
      })
    }
  }

  # Ingot's local blob storage stays over its own budget. The threshold is the
  # budget itself, local_blob_max_bytes, which each node sets; this rule chooses
  # no number. Ingot's sweeper evicts cached bodies every 30s to stay under it,
  # so usage that stays over means what is left is bodies it may not evict:
  # uploads in flight, or uploads that failed (fil-forge/ingot's README, "Local
  # disk").
  #
  # A node with no budget publishes 0, which `> 0` drops, so it produces no
  # series and no_data_state = OK keeps it quiet. for = 15m is chosen: a burst
  # of uploads can hold the spool over budget for minutes without anything
  # being wrong. An instant query, so no reduce stage.
  rule {
    name           = "Ingot local disk over budget"
    condition      = "B"
    for            = "15m"
    no_data_state  = "OK"
    exec_err_state = "Error"

    annotations = {
      summary          = "Ingot on {{ $labels.appliance }} ({{ $labels.node }}) is over its local disk budget"
      description      = "Ingot's spool and cache together have held more than local_blob_max_bytes for fifteen minutes. The sweeper cannot evict what is left: bodies being uploaded, or bodies whose upload failed (see the stalled uploads panel)."
      __dashboardUid__ = "forge-regions"
      __panelId__      = "17"
    }

    labels = {
      team_name = "forge"
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
          sum by (appliance, region, node) (ingot_local_blobs_usage_bytes{${local.ingot_matcher}})
          /
          max by (appliance, region, node) (ingot_local_blobs_budget_bytes{${local.ingot_matcher}} > 0)
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
          evaluator = { type = "gt", params = [1] }
        }]
      })
    }
  }

  # Ingot's stalled uploads are growing. Ingot reports the bytes of bodies whose
  # upload has stalled -- intents still spooled or uploading an hour after their
  # last state change -- and nothing reclaims them yet, so the figure only falls
  # when someone removes them by hand. Firing on any stalled byte would
  # therefore fire for good after one failure. Growth is the signal instead:
  # more stalled bytes now than an hour ago means uploads are still failing.
  #
  # The hour is Ingot's own cutoff, not a choice here; the window matches it so
  # one failure shows as growth for about an hour and then resolves. for = 0m
  # because the gauge has already waited that hour. no_data_state is OK: an
  # Ingot without the metric, or without metrics at all, is the container
  # rule's business, not this one's.
  rule {
    name           = "Ingot uploads are stalling"
    condition      = "B"
    for            = "0m"
    no_data_state  = "OK"
    exec_err_state = "Error"

    annotations = {
      summary          = "Ingot on {{ $labels.appliance }} ({{ $labels.node }}) has more stalled uploads than an hour ago"
      description      = "Bodies whose upload failed are piling up in Ingot's spool. They count against the local disk budget and nothing reclaims them yet; Ingot's logs say why the uploads failed."
      __dashboardUid__ = "forge-regions"
      __panelId__      = "18"
    }

    labels = {
      team_name = "forge"
      component = "appliance"
      severity  = "warning"
    }

    data {
      ref_id         = "A"
      datasource_uid = var.prometheus_datasource_uid

      relative_time_range {
        from = 7200
        to   = 0
      }

      model = jsonencode(merge(local.query_defaults, {
        refId      = "A"
        instant    = true
        range      = false
        intervalMs = 1000
        expr       = <<-PROMQL
          sum by (appliance, region, node) (
            delta(ingot_local_blobs_stalled_bytes{${local.ingot_matcher}}[1h])
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

# Its own group at 60s. A stopped container should reach Slack within ten
# minutes, and the 300s the other appliance rules run at cannot do it: one
# scrape gap plus the 5m absence window plus one evaluation is about eleven
# minutes. At 60s it is about six.
resource "grafana_rule_group" "appliance_containers" {
  name             = "Forge Regions containers"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 60

  # Absence is the signal. cAdvisor stops publishing a container's series when
  # the container goes away, so there is no value to compare against a
  # threshold; the expression tests for a series that was there and is not. The
  # clauses are annotated inline below.
  #
  # Only staging is watched, because only staging runs cAdvisor -- the dev EC2
  # node's Alloy container has no cgroup mount
  # (infra-nodes/docs/observability.md). Where it does not run every clause is
  # absent, so the rule is silent rather than firing for every container.
  #
  # Known blind spot: a node whose cAdvisor dies is deliberately not watched by
  # this rule (see the `and on (node)` gate), and nothing else covers it.
  # "Appliance has stopped reporting" reads the deploy stamp rather than
  # cAdvisor, so a live node with a dead scrape goes unnoticed. Closing it needs
  # a rule on the scrape's own health.
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
      team_name = "forge"
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
            # 24h rather than "ever", so this is self-cleaning: a service dropped
            # from a Compose project falls out of both sides and stops alerting
            # with no edit here. The cost is that a container down longer than a
            # day stops alerting too, the same trade the node rule makes.
            max by (node, region, appliance, service_name) (
              present_over_time(container_cpu_usage_seconds_total{${local.container_matcher}}[24h])
            )
            unless
            # Recovery clears the alert as soon as one sample lands in this window.
            max by (node, region, appliance, service_name) (
              present_over_time(container_cpu_usage_seconds_total{${local.container_matcher}}[5m])
            )
          )
          # Gate: only alert on a node cAdvisor is still reporting from. Without
          # it, a scrape that dies after a container has reported leaves the 24h
          # side present and the 5m side empty, and every watched container on
          # that node pages at once. no_data_state does not help -- the stale 24h
          # series is data, not no-data. job="cadvisor" is a far wider net than
          # the watched services (it covers the host's other containers, Lotus
          # and Sophon among them), so the gate holds while cAdvisor lives even
          # with every watched container down, and goes false the moment the
          # scrape does.
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

variable "usage_datasource_uid" {
  description = "UID of the grafanacloud-usage data source, where Grafana Cloud publishes the stack's own ingestion rates. It is the last segment of the data source's settings page URL, and it is not a secret. Null leaves the trace volume rule out."
  type        = string
  default     = null
}

variable "trace_spans_alert_threshold" {
  description = "Spans per second, averaged over six hours, above which the trace volume rule fires. Take it from what the plan's traces allowance comes to per second, or from a multiple of the rate Explore shows today. Null leaves the trace volume rule out."
  type        = number
  default     = null
}

# Trace volume, as a nudge rather than an alarm. Spans cost money by volume and
# nothing else here would say that a change -- a new span on a frequent code
# path, say -- has raised it, so this watches the rate Grafana Cloud reports
# receiving for the whole stack. It cannot say which service sent them; the
# span names in Tempo can.
#
# Everything about it is set to stay quiet:
#
#   - It averages the rate over six hours and needs that average over the
#     threshold for an hour more, so a burst never fires it, and it evaluates
#     every fifteen minutes because nothing about it is urgent.
#   - severity is info, so a route in the policy tree can send it somewhere
#     quieter than the warnings; until one does, it goes wherever the forge
#     route sends everything else.
#   - no_data_state and exec_err_state are both OK. A gap in the usage data is
#     not something to be told about at this level of concern.
#
# It exists only once both variables above are set, so this merges as nothing.
# Before setting them, forge-terraform needs datasources:query on
# grafanacloud-usage, for the reason the header of this file gives.
#
# Grafana Cloud's own usage alerts, set in the Cost management pages rather than
# here, are the backstop for the monthly total. This rule is for noticing a
# change in rate before a month of it has accrued.
resource "grafana_rule_group" "usage" {
  count = var.usage_datasource_uid != null && var.trace_spans_alert_threshold != null ? 1 : 0

  name             = "Forge Usage"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 900

  rule {
    name           = "Trace volume is above its threshold"
    condition      = "B"
    for            = "1h"
    no_data_state  = "OK"
    exec_err_state = "OK"

    annotations = {
      summary     = "The stack has received more than ${var.trace_spans_alert_threshold} spans per second on average over six hours"
      description = "Trace ingestion has risen. In Explore, sum(grafanacloud_traces_instance_spans_received_total:rate5m) on grafanacloud-usage shows when; in Tempo, grouping recent spans by name shows which. Raise the threshold if the new rate is expected."
    }

    labels = {
      team_name = "forge"
      component = "usage"
      severity  = "info"
    }

    data {
      ref_id         = "A"
      datasource_uid = var.usage_datasource_uid

      relative_time_range {
        from = 21600
        to   = 0
      }

      model = jsonencode(merge(local.query_defaults, {
        refId   = "A"
        instant = true
        range   = false
        expr    = <<-PROMQL
          sum(avg_over_time(grafanacloud_traces_instance_spans_received_total:rate5m[6h]))
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
          evaluator = { type = "gt", params = [var.trace_spans_alert_threshold] }
        }]
      })
    }
  }
}
