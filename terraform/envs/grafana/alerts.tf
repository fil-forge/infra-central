# Grafana alert rules for Forge, in their own folder. folders.tf sets out why
# these are git only where the dashboards beside them are not.
#
# The expression stages address __expr__ and repeat their own refId in the
# condition's query.params. That is unusual -- the provider's documentation
# shows neither -- but it is the shape Grafana's own rule export produces and
# the shape that applies cleanly here. Follow the rules already in this file
# rather than the provider docs.
#
# Of the seven alerts under FIL-1145 only FIL-1209 states a threshold. The rest
# say "too high", or defer to an SLO that has not been written (FIL-1242), or
# ask for a decision the team has not taken (FIL-1211, FIL-1212); they are
# listed at the end of this file rather than guessed at.
#
# Writing a rule needs two permissions on forge-terraform beyond folder Admin,
# and neither is sufficient alone:
#
#   - `alert.provisioning.provenance:write`, carried by the fixed role
#     `fixed:alerting.provisioning.provenance:writer` and shown in the UI as
#     "Alerting:Set provisioning status". Unscoped. It satisfies the routing
#     middleware, which demands a permission no folder grant can confer
#     (ngalert/api/authorization.go, the PUT rule-groups case).
#
#   - `datasources:query` on grafanacloud-prom, granted on the data source's
#     own Permissions tab rather than through a role. Once past the middleware
#     the handler checks every data source the rules read
#     (ngalert/accesscontrol/rules.go, getRulesQueryEvaluator). Expression
#     nodes are skipped, which is why the folders and dashboards in this root
#     apply without it.
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

  # The appliance containers that are meant to stay up. On staging -- the only
  # stage with cAdvisor -- these four are exactly the services declared
  # `restart: unless-stopped` in infra-nodes' nodes/<node>/{apps,platform}. The
  # fifth service there, postgres-init, is `restart: "no"`: exiting is what it
  # is for.
  #
  # An allow-list rather than a pattern because a Compose restart policy is not
  # a label cAdvisor exports, so nothing in the query can tell a service that
  # should be running from one that should have exited. A service added to a
  # Compose project and not added here is not watched -- dev's caddy and alloy
  # already are not, which costs nothing while dev ships no cAdvisor.
  #
  # Narrowing by service_name rather than by node keeps the host's own
  # containers out: on the Servers.com box cAdvisor also reports Lotus, Sophon
  # and everything else it runs, none of which carries an appliance
  # service_name.
  #
  # Prometheus anchors the whole regex, so these match exactly, not as prefixes.
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

  # Any error out of the provision Lambda. The threshold is gt 0 because no
  # number was ever specified and a provisioning error is always worth a look.
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

# 300s although the host exporter is scraped once a minute. Nothing in this
# group is time-critical enough to want the extra resolution, and a slower
# interval costs nothing here.
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
}

# Its own group at 60s. FIL-1163 wants a Slack alert "within ten minutes" of a
# container stopping, and the 300s the other appliance rules run at cannot meet
# it: one scrape gap plus the 5m absence window plus one evaluation is about
# eleven minutes. At 60s it is about six.
resource "grafana_rule_group" "appliance_containers" {
  name             = "Forge appliance containers"
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
