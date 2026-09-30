# Grafana alert rules for Forge, in their own folder. folders.tf sets out why
# these are git only where the dashboards beside them are not.
#
# Nine rules, in two groups so Central and the appliances can evaluate at
# different intervals: CloudWatch publishes once a minute, the appliance host
# exporter is scraped once a minute but nothing here needs that resolution.
#
# Three of the nine came from rules built by hand in the UI and exported; the
# shapes below follow that export rather than the provider's documentation,
# which is why the expression stages address __expr__ and put their own refId in
# the condition's query.params. The fourth is FIL-1209's disk rule. The fifth,
# Piri's chain notifications, is the only one that reads logs rather than
# metrics. The last four read the chain head and proving gauges Piri exports
# over OTLP, and between them replace that log rule once every alerting stage
# runs a Piri that has them.
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

variable "loki_datasource_uid" {
  description = "UID of the grafanacloud-filecoinfoundation-logs data source, the stack's Loki. Addressed by uid for the same reason as the Prometheus one. It is in the URL of the data source's settings page, and it is not a secret."
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

  # Piri's container log stream. Alloy names it appliance-<stage>-<region>-piri
  # from the Compose service and stamps appliance, region and node on it
  # (infra-nodes nodes/dev/platform/config/alloy/config.alloy), so the same
  # appliance matcher narrows it to the alerting stages.
  piri_log_matcher = "appliance=~\"(${local.stages})-.*\", service_name=~\"appliance-.*-piri\""

  # Piri's OTLP metrics, and the target_info series that carries its resource
  # attributes. Alloy's OTLP conversion sets job to service.namespace/
  # service.name, forge/piri since Piri reports the forge namespace, and the
  # remote writer's external_labels stamp appliance, region and node on every
  # series it sends, target_info included (infra-nodes
  # nodes/dev/platform/config/alloy/config.alloy). appliance_matcher cannot be
  # reused: its service_name is the host exporter's.
  piri_metric_matcher = "appliance=~\"(${local.stages})-.*\", job=\"forge/piri\""

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
  #
  # Superseded by "Piri's chain head is stale" and the three rules after it,
  # which read the head and the proving schedule directly, once the alerting
  # stages run a Piri that exports those gauges. Kept until then, since a Piri
  # without them leaves this rule the only one watching the chain; delete it
  # after that rather than run both.
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
      team      = "forge"
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

  # The four rules below read gauges Piri exports from its PDP pipeline (piri
  # docs/content/operator-guide/monitoring.md, "PDP Proving Health"), starting
  # from the PromQL given there. They are grouped by node as well as region for
  # the reason the disk rule gives. Filecoin epochs are thirty seconds, which is
  # where every 30 below comes from.

  # The timestamp of the last tipset Piri's chain scheduler applied, against the
  # wall clock. Five minutes is ten tipsets, far past what null rounds or a slow
  # block produce, so this is Lotus stalled or unreachable, or Piri's
  # subscription to it stuck.
  #
  # `for` is 5m, the shortest pending period a group evaluated every five
  # minutes can give: one more evaluation to confirm the first. The threshold
  # already holds five minutes of grace.
  #
  # no_data_state is OK: a Piri that has not seen a head since it started, or
  # one that exports no chain gauges at all, has no series here. The first is
  # the next rule's job; the second is a Piri older than these metrics.
  rule {
    name           = "Piri's chain head is stale"
    condition      = "B"
    for            = "5m"
    no_data_state  = "OK"
    exec_err_state = "Error"

    annotations = {
      summary     = "Piri on {{ $labels.node }} ({{ $labels.region }}) has not seen a new chain head for more than five minutes"
      description = "The last tipset Piri's chain scheduler applied is more than five minutes old. Filecoin produces one every thirty seconds, so the Lotus it reads the chain from is stalled, out of sync or unreachable, or Piri's subscription to it is stuck, and Piri cannot schedule or submit proofs. Check the sync status of that Lotus (`lotus sync wait` or `lotus chain head` on the host that owns it) and run `piri status` in the Piri container."
      runbook_url = "https://github.com/fil-forge/infra-nodes/blob/main/docs/RUNBOOK.md#when-something-is-wrong"
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
        from = 600
        to   = 0
      }

      model = jsonencode(merge(local.query_defaults, {
        refId      = "A"
        instant    = true
        range      = false
        intervalMs = 1000
        expr       = <<-PROMQL
          time() - max by (appliance, region, node) (
            piri_chain_head_timestamp_seconds{${local.piri_metric_matcher}}
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
          evaluator = { type = "gt", params = [300] }
        }]
      })
    }
  }

  # Piri is reporting but its chain scheduler has never applied a head. The head
  # gauges appear only once the first tipset arrives after start-up, which with
  # a working Lotus is within seconds, so a Piri that restarted against a Lotus
  # it cannot reach has no head series at all and the rule above never sees it.
  #
  # target_info is the evidence Piri is up: it carries the same job and
  # appliance, region and node labels as every other Piri series, so the same
  # matcher applies to it. On its own it would also match every Piri too old to
  # export the head, which is every Piri until these metrics are deployed. So
  # the node must also export one of the gauges Piri reads from its database,
  # which do not depend on the chain: they prove the running Piri has the
  # metrics, and so that the missing head means something. A node with no proof
  # sets and no successful proof yet is left out, and has nothing to lose.
  #
  # Five-minute windows are ten of Piri's thirty-second pushes. `for` is 10m, so
  # a restart that takes a moment to reach Lotus does not fire.
  #
  # no_data_state is OK, and not NoData, even though "no head" is what the rule
  # is about: the `unless` is what finds the missing head, so the result is
  # empty on every healthy node, and NoData would page for the whole fleet. It
  # also means a Piri that has stopped reporting entirely, target_info and all,
  # is not caught here; nothing in this file watches for that yet.
  rule {
    name           = "Piri is reporting but has no chain head"
    condition      = "B"
    for            = "10m"
    no_data_state  = "OK"
    exec_err_state = "Error"

    annotations = {
      summary     = "Piri on {{ $labels.node }} ({{ $labels.region }}) is running but has not seen a chain head"
      description = "Piri is exporting metrics but its chain scheduler has not applied a single tipset since it started, so it cannot schedule or submit proofs. Usually the Lotus it reads the chain from is unreachable or was down when Piri started. Check that Lotus is up and synced (`lotus sync wait` or `lotus chain head` on the host that owns it), that Piri's Lotus endpoint and token are right, and run `piri status` in the Piri container."
      runbook_url = "https://github.com/fil-forge/infra-nodes/blob/main/docs/RUNBOOK.md#when-something-is-wrong"
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
          max by (appliance, region, node) (
            present_over_time(target_info{${local.piri_metric_matcher}}[5m])
          )
          and
          (
            max by (appliance, region, node) (
              present_over_time(piri_pdp_task_last_success_timestamp_seconds{${local.piri_metric_matcher}}[5m])
            )
            or
            max by (appliance, region, node) (
              present_over_time(piri_pdp_proofset_next_challenge_epoch{${local.piri_metric_matcher}}[5m])
            )
          )
          unless
          max by (appliance, region, node) (
            present_over_time(piri_chain_head_timestamp_seconds{${local.piri_metric_matcher}}[5m])
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

  # A proof set whose challenge window has closed without its next proving
  # period being scheduled: epochs past the window's close, per proof set. The
  # current epoch is the last head plus the wall-clock time since it, so this
  # still fires when the head itself is stale.
  #
  # Some overshoot is normal. Curio's NextProvingPeriod watcher
  # (tasks/pdpv0/task_next_pp.go) only queues the task once a head reaches
  # prove_at_epoch + challenge_window, and the task moves prove_at_epoch on
  # when it sends nextProvingPeriod, without waiting for it to land. Add
  # harmonytask's three-second poll, a handful of contract reads and Piri's
  # thirty-second push, and a healthy proof set is a few epochs past its window
  # for a minute or two each period, which an evaluation can catch. `for` is
  # 10m: three evaluations in a row, twenty epochs, which that never reaches,
  # while a scheduling task that is failing, or held back by the hundred-epoch
  # backoff curio applies after a failed attempt, stays past the window for
  # longer than that.
  #
  # no_data_state is OK: a node with no proof sets, or a proof set with no next
  # challenge (briefly between periods, or proving disabled), has no series.
  rule {
    name           = "Piri proof set is past its challenge window"
    condition      = "B"
    for            = "10m"
    no_data_state  = "OK"
    exec_err_state = "Error"

    annotations = {
      summary     = "Proof set {{ $labels.proof_set }} on {{ $labels.node }} ({{ $labels.region }}) is past its challenge window"
      description = "The proof set's challenge window closed more than ten minutes ago and Piri has not scheduled its next proving period, so this period's proof is missed or at risk and the proof set may be faulted on chain. Check that the Lotus Piri reads the chain from is synced, run `piri status`, and read the proof set's on-chain state with `piri client pdp proofset state` in the Piri container; the PDPv0_Prove and PDPv0_ProvPeriod task logs say why it failed."
      runbook_url = "https://github.com/fil-forge/infra-nodes/blob/main/docs/RUNBOOK.md#when-something-is-wrong"
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
              max by (appliance, region, node) (piri_chain_head_epoch{${local.piri_metric_matcher}})
            + (time() - max by (appliance, region, node) (piri_chain_head_timestamp_seconds{${local.piri_metric_matcher}})) / 30
          )
          - on (appliance, region, node) group_right
          max by (appliance, region, node, proof_set) (
              piri_pdp_proofset_next_challenge_epoch{${local.piri_metric_matcher}}
            + piri_pdp_proofset_challenge_window_epochs{${local.piri_metric_matcher}}
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

  # The backstop: no successful PDPv0_Prove on the node in one and a half
  # proving periods. The value is the time since the last success in proving
  # periods, so the threshold is 1.5.
  #
  # Per node, not per proof set: one proof set proving keeps it quiet while
  # another does not, which is the rule above's job. What this adds is the case
  # that rule cannot see. A proof set curio gives up on after repeated failures
  # has its next challenge cleared and drops out of the proof set gauges
  # altogether. The period is read over three days for that reason, so it
  # outlasts one and a half of the longest period (2880 epochs, a day) after
  # the gauge is gone, and still lapses on its own once proving on the node has
  # ended for good.
  #
  # `for` is 10m. The threshold is the grace; this only confirms it.
  #
  # no_data_state is OK: a node that has never proved, or has no proof sets in
  # three days, has no series.
  rule {
    name           = "Piri has not proved in 1.5 proving periods"
    condition      = "B"
    for            = "10m"
    no_data_state  = "OK"
    exec_err_state = "Error"

    annotations = {
      summary     = "Piri on {{ $labels.node }} ({{ $labels.region }}) has not submitted a successful proof in 1.5 proving periods"
      description = "No PDPv0_Prove task has succeeded on this node for more than one and a half proving periods, so at least one proving period has passed without a proof. Check that the Lotus Piri reads the chain from is synced, run `piri status`, and check each proof set with `piri client pdp proofset state` in the Piri container; the PDPv0_Prove task logs say why proofs are failing."
      runbook_url = "https://github.com/fil-forge/infra-nodes/blob/main/docs/RUNBOOK.md#when-something-is-wrong"
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
          (
            time() - max by (appliance, region, node) (
              piri_pdp_task_last_success_timestamp_seconds{${local.piri_metric_matcher}, task_name="PDPv0_Prove"}
            )
          )
          / on (appliance, region, node)
          (
            30 * max by (appliance, region, node) (
              max_over_time(piri_pdp_proofset_proving_period_epochs{${local.piri_metric_matcher}}[3d])
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
          evaluator = { type = "gt", params = [1.5] }
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
