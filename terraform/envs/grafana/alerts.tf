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

variable "usage_datasource_uid" {
  description = "UID of the grafanacloud-usage data source, where Grafana Cloud publishes the stack's own ingestion rates. It is the last segment of the data source's settings page URL, and it is not a secret. Null leaves the trace volume rule out."
  type        = string
  default     = null
}

variable "trace_spans_alert_threshold" {
  description = "Spans per second, averaged over six hours, above which the trace volume rule fires. A multiple of the rate Explore shows today is a reasonable start. Null leaves the trace volume rule out."
  type        = number
  default     = null
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

  # OpenBao's container log stream, same scheme.
  openbao_log_matcher = "appliance=~\"(${local.stages})-.*\", service_name=~\"appliance-.*-openbao\""

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

  # Alloy's own scrapes, selected by the labels each one actually arrives with.
  #
  # `up` is one series per target, not per container, so the two selectors
  # cannot be the same. The host exporter and Caddy are each routed through a
  # prometheus.relabel component that sets service_name on every series, so
  # their `up` carries it (infra-nodes docs/RUNBOOK.md, staging section). The
  # cAdvisor scrape is routed through the rules that read a container's Compose
  # labels, which `up` does not have, so its `up` arrives carrying only the
  # appliance label that remote_write puts on everything from the box, plus job
  # and instance. Observed 2026-10-07: up{appliance="staging-eu-central-3",
  # instance="ff", job="cadvisor"}.
  #
  # Scoping matters here. The appliance's Alloy also ships telemetry for
  # workloads that are not ours and for remote targets, and every one of those
  # series carries the appliance label too, so a rule matching on that alone
  # would page us about somebody else's exporter. service_name is what keeps the
  # first selector to our own scrapes. `job` does less than that for the second:
  # the appliance runs one cAdvisor and it reports the host's other containers
  # too, as the container rule's own gate comment says. So that selector names a
  # shared scrape we depend on rather than one we own, which is still worth
  # knowing about when it goes dark.
  #
  # service_name is deliberately not narrowed to host and caddy: a scrape added
  # later is then watched from the day it ships, which is the same trade
  # container_matcher makes above.
  scrape_matcher   = "service_name=~\"appliance-(${local.stages})-.*\""
  cadvisor_matcher = "job=\"cadvisor\", appliance=~\"(${local.stages})-.*\""

  # The stage as a label of its own, for routing. Production critical alerts
  # page where staging's notify, and a route can only tell them apart by a label
  # the alert carries. Central's rules take one from their queries. The
  # appliance's take it from the appliance label, <stage>-<region> by
  # construction, cut at its first hyphen as the dashboard link below does.
  # Adding it changed every appliance alert instance's identity once, when it
  # landed.
  #
  # An instance raised because the query failed or came back empty carries
  # none of the query's labels, so it has no stage, and a route that matches
  # stage = "prod" will not see it. Routing has to treat a critical alert
  # without a stage as possibly production; docs/observability.md says how.
  appliance_stage_label = "{{ reReplaceAll \"-.*\" \"\" $labels.appliance }}"

  # A dashboard link that carries the stage, and for the appliance the region.
  #
  # Grafana builds the notification's dashboardURL and panelURL from
  # __dashboardUid__ and __panelId__, and both come out as a bare /d/<uid> with
  # no variables on it. The dashboards then open on whatever stage they default
  # to, which is prod, while the only appliance is on staging -- so an alert's
  # own link showed the on-call an empty dashboard for a stage that had not
  # fired, which is the failure these rules exist to prevent, one level up.
  #
  # A URL Grafana does not build can carry them. Central's rules already derive
  # a stage label in their queries; the appliance's do not, and the appliance
  # label is <stage>-<region>, so reReplaceAll cuts it at the first hyphen.
  #
  # The __ pair stays. It is what ties a rule to its panel inside Grafana's own
  # UI, and removing it would empty panelURL in the payload again. This is the
  # link to follow from a page; that one is for the rule's own page.
  #
  # The host repeats the provider's url in main.tf. There is one stack, and no
  # variable for it to share yet.
  central_dashboard = "https://filecoinfoundation.grafana.net/d/forge-central?var-stage={{ $labels.stage }}"
  regions_dashboard = "https://filecoinfoundation.grafana.net/d/forge-regions?var-stage={{ reReplaceAll \"-.*\" \"\" $labels.appliance }}&var-region={{ $labels.region }}"

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
      dashboard_url    = "${local.central_dashboard}&viewPanel=6"
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
      dashboard_url    = "${local.central_dashboard}&viewPanel=3"
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
      stage     = "{{ reReplaceAll \"^fc-(.*)-provision$\" \"$1\" $labels.dimension_FunctionName }}"
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

  # A tunnel of the compatibility server's site-to-site VPN is down. Each VPN
  # connection has two, and the appliance moves its database route to the other
  # one, so a single tunnel down leaves the database reachable without
  # redundancy. AWS takes tunnels down one at a time for maintenance, which
  # fires this too. Until an appliance has strongSwan configured, both of its
  # tunnels are down and this fires from the moment the connection exists.
  #
  # TunnelState per VpnId is 1 with every tunnel up, 0 with none, and in between
  # otherwise. The same metric is also published per tunnel address, which the
  # empty TunnelIpAddress matcher leaves out. The VpnId series carry no stage, and the non-prod account holds
  # two stages, so the rule watches the prod account only; prod is the one stage
  # with sites (modules/shared/constants, pandora_sites).
  rule {
    name           = "Pandora VPN tunnel down"
    condition      = "B"
    for            = "10m"
    no_data_state  = "OK"
    exec_err_state = "Error"

    annotations = {
      summary     = "VPN connection {{ $labels.dimension_VpnId }} in AWS account {{ $labels.account_id }} has a tunnel down"
      description = "At least one tunnel of the compatibility server's VPN connection {{ $labels.dimension_VpnId }} in AWS account {{ $labels.account_id }} has been down for ten minutes; with both down, the appliance cannot reach the pandora database. The VPC console's Site-to-Site VPN connections page shows each tunnel's status and the reason. docs/pandora-vpn.md covers the appliance side."
    }

    labels = {
      team_name = "forge"
      component = "central"
      stage     = "prod"
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
        legendFormat = "{{account_id}} {{dimension_VpnId}}"
        expr         = <<-PROMQL
          min by (account_id, dimension_VpnId) (
            aws_vpn_tunnel_state_minimum{account_id="${module.constants.prod_account_id}", dimension_VpnId!="", dimension_TunnelIpAddress=""}
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
  #
  # Recovery is a no-data event, not a falling value. A fresh stamp fails the
  # `> 900` filter and the node is present again, so both branches return
  # nothing and there is no series left to go below a threshold.
  # no_data_state = OK is what turns that into Normal; Alerting or NoData here
  # would leave the rule firing after the node had recovered.
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
      dashboard_url    = "${local.regions_dashboard}&viewPanel=13"
      __dashboardUid__ = "forge-regions"
      __panelId__      = "13"
    }

    labels = {
      team_name = "forge"
      component = "appliance"
      stage     = local.appliance_stage_label
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
  #
  # no_data_state was NoData, which meant a dark host exporter raised a
  # DatasourceNoData instance here carrying this rule's own labels, and so a
  # notification about disk space when the subject was the scrape. It is OK now
  # that "Appliance metrics scrape is failing" says that directly and sooner.
  # The two are a pair: this rule is deliberately silent about absent data
  # because another one is not, so do not delete that rule without putting this
  # back.
  rule {
    name           = "Appliance free disk space below 40%"
    condition      = "B"
    for            = "15m"
    no_data_state  = "OK"
    exec_err_state = "Error"

    annotations = {
      summary          = "{{ $labels.appliance }} has less than 40% free on {{ $labels.mountpoint }}"
      description      = "{{ $labels.node }} is below 40% free on {{ $labels.mountpoint }}. Volumes and their sizes are in infra-nodes' terraform/modules/node."
      runbook_url      = "https://github.com/fil-forge/infra-nodes/blob/main/docs/RUNBOOK.md#when-something-is-wrong"
      dashboard_url    = "${local.regions_dashboard}&viewPanel=8"
      __dashboardUid__ = "forge-regions"
      __panelId__      = "8"
    }

    labels = {
      team_name = "forge"
      component = "appliance"
      stage     = local.appliance_stage_label
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
      stage     = local.appliance_stage_label
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
      stage     = local.appliance_stage_label
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
      summary          = "{{ $labels.host }} on {{ $labels.node }} is returning 5xx for more than 5% of requests"
      description      = "Caddy has answered more than one request in twenty with a 5xx for ten minutes. A 502 is Caddy failing to reach the upstream, so check the container is running and healthy; a 500 came from Piri or Ingot itself, so read its log. Split by code and handler: sum by (code, handler) (rate(caddy_http_request_duration_seconds_count{host=\"{{ $labels.host }}\", code=~\"5..\"}[5m]))."
      runbook_url      = "https://github.com/fil-forge/infra-nodes/blob/main/docs/RUNBOOK.md#when-something-is-wrong"
      dashboard_url    = "${local.regions_dashboard}&viewPanel=14"
      __dashboardUid__ = "forge-regions"
      __panelId__      = "14"
    }

    labels = {
      team_name = "forge"
      component = "appliance"
      stage     = local.appliance_stage_label
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
      dashboard_url    = "${local.regions_dashboard}&viewPanel=17"
      __dashboardUid__ = "forge-regions"
      __panelId__      = "17"
    }

    labels = {
      team_name = "forge"
      component = "appliance"
      stage     = local.appliance_stage_label
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
  # last state change -- and nothing reclaims a failed PUT's yet (a multipart
  # part's goes with its session), nor may they be deleted by hand (Ingot's
  # README), so the figure rarely falls. Firing on any stalled byte would
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
      description      = "Bodies whose upload did not finish are piling up in Ingot's spool: the upload failed, or it reached the provider and recording that failed. They count against the local disk budget, and nothing reclaims a failed PUT's yet (a multipart part's goes with its session); Ingot's logs say what failed."
      dashboard_url    = "${local.regions_dashboard}&viewPanel=18"
      __dashboardUid__ = "forge-regions"
      __panelId__      = "18"
    }

    labels = {
      team_name = "forge"
      component = "appliance"
      stage     = local.appliance_stage_label
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

  # Alloy tried to scrape an exporter and failed. Worth its own rule because the
  # panels built on each scrape read *no data* rather than zero when it is dark,
  # and a panel reading no errors looks much like one reading none.
  #
  # == bool 0 rather than == 0, which would keep the series and leave its value
  # at 0 -- the threshold stage below is `gt 0`, so the filter form would never
  # fire. The bool form scores every target instead, 1 for a failed scrape and 0
  # for a good one, which also means recovery is a value falling rather than a
  # series vanishing.
  #
  # No absence branch: a node that has gone away stops producing `up` at all, so
  # this rule falls silent and "Appliance has stopped reporting" is the one that
  # fires. That deduplicates node death and nothing else, and the common case is
  # worth being plain about rather than claiming more. The deploy stamp is a
  # textfile-collector gauge on this same host exporter, so a wedged exporter on
  # a live box *is* the stamp going stale: this fires at about eight minutes
  # naming the exporter, the node rule follows at about twenty-five under a
  # summary that reads as though the box were gone, and the disk rule's
  # no_data_state = "NoData" adds a third notification. Earlier and specific is
  # worth that; a quieter rule here would only mean learning it later and worse.
  rule {
    name           = "Appliance metrics scrape is failing"
    condition      = "B"
    for            = "5m"
    no_data_state  = "OK"
    exec_err_state = "Alerting"

    annotations = {
      summary          = "{{ $labels.service_name }} is not answering Alloy on {{ $labels.node }}"
      description      = "Alloy reached this exporter and got nothing back, so every panel built on it reads no data rather than zero. The host scrape carries CPU, memory, disk and the reconcile age; the Caddy scrape carries the request and error panels, and Caddy failing to answer here may mean the public surface is down with it."
      runbook_url      = "https://github.com/fil-forge/infra-nodes/blob/main/docs/RUNBOOK.md#when-something-is-wrong"
      dashboard_url    = "${local.regions_dashboard}&viewPanel=3"
      __dashboardUid__ = "forge-regions"
      __panelId__      = "3"
    }

    labels = {
      team_name = "forge"
      component = "appliance"
      stage     = local.appliance_stage_label
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
        legendFormat = "{{service_name}}"
        expr         = <<-PROMQL
          max by (appliance, node, region, service_name) (
            up{${local.scrape_matcher}} == bool 0
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

  # The labelling convention, alerted on rather than written down.
  #
  # Every per-box rule in this file needs `node`, because `appliance` is
  # <stage>-<region> and cannot tell two boxes in one region apart. The host and
  # Caddy scrapes carry node because each is routed through a relabel component
  # that sets it on every series; the cAdvisor scrape is routed through rules
  # that read a container's Compose labels, which `up` does not have, so its
  # `up` arrives without one. That is a convention living in a config outside
  # these repositories, and conventions in prose get dropped when the config is
  # re-implemented -- which it will be, at the next box and again if the
  # appliance ever runs its own Alloy.
  #
  # So this fires while the convention is broken, and goes quiet when it is
  # kept. Prometheus reads an absent label as empty, so node="" selects exactly
  # the series missing one. `count` rather than the value, because `up` is 1 for
  # a healthy scrape and the signal here is that the series exists at all.
  #
  # What it cannot see: a scrape that drops `node` *and* has neither
  # job="cadvisor" nor an appliance service_name is indistinguishable from the
  # host's other workloads, and nothing can catch that.
  #
  # No dashboard link, because no panel shows label health. The fix is in the
  # staging section of infra-nodes docs/RUNBOOK.md, which specifies the labels
  # each scrape has to set.
  rule {
    name           = "Appliance telemetry is missing its node label"
    condition      = "B"
    for            = "10m"
    no_data_state  = "OK"
    exec_err_state = "Alerting"

    annotations = {
      summary     = "{{ $labels.appliance }} is shipping telemetry with no node label"
      description = "A scrape on this appliance is arriving without the node label every per-box rule needs. While that is true, anything reading these series can only work at region granularity, so a second box in the region would be invisible behind the first. Set node and region on the scrape in the host's Alloy config, as the staging section of infra-nodes docs/RUNBOOK.md specifies."
      runbook_url = "https://github.com/fil-forge/infra-nodes/blob/main/docs/RUNBOOK.md#when-something-is-wrong"
    }

    labels = {
      team_name = "forge"
      component = "appliance"
      stage     = local.appliance_stage_label
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
        legendFormat = "{{appliance}} {{job}}{{service_name}}"
        expr         = <<-PROMQL
          count by (appliance, job, service_name) (
            up{appliance=~"(${local.stages})-.*", node="", job="cadvisor"}
            or
            up{appliance=~"(${local.stages})-.*", node="", ${local.scrape_matcher}}
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
  # That shape makes recovery a no-data event too: a container that comes back
  # satisfies both present_over_time clauses, the `unless` cancels them, and the
  # rule has nothing left to evaluate. So no_data_state = OK is what lets the
  # rule clear, as well as what keeps it quiet where cAdvisor does not run.
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
      dashboard_url    = "${local.regions_dashboard}&viewPanel=21"
      __dashboardUid__ = "forge-regions"
      __panelId__      = "21"
    }

    labels = {
      team_name = "forge"
      component = "appliance"
      stage     = local.appliance_stage_label
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

  # The blind spot the rule above names, closed.
  #
  # "Appliance container is not running" holds itself silent while cAdvisor is
  # dark, because the alternative is every watched container paging at once. So
  # a dead cAdvisor is not a quiet dashboard, it is nothing watching the
  # containers at all, and only a rule on the scrape itself can say so.
  #
  # Two shapes, because how cAdvisor's target fails depends on how the host's
  # Alloy declares it, and that config lives outside these repositories. A
  # static target stays and its scrape fails, giving up == 0; a discovered one
  # disappears with the container and gives no series at all. The first branch
  # catches the former and the second the latter, so this holds either way.
  #
  # The gate is what keeps a dead node from paging twice: no host scrape in the
  # last five minutes means the box is gone, which is "Appliance has stopped
  # reporting"'s to tell. `and` binds tighter than `or`, hence the parentheses
  # around the pair.
  #
  # The branches are not equally quick, and it is better not to imply they are.
  # A failing static target is true at the next scrape, so roughly five minutes
  # once `for` has run; a vanished discovered one needs the 5m window to empty
  # first, so roughly ten.
  #
  # `for = 5m` is load-bearing rather than debounce. On node death the absence
  # branch and the gate are driven by the same five-minute window on the same
  # stream, and `for` is what absorbs the skew between them so they lapse
  # together instead of racing into a page. The rule beside this one runs
  # `for = 0m`; harmonising the two would turn every node death into a second
  # page.
  #
  # Grouped by node as well as appliance, although cAdvisor's `up` carries no
  # node label today. `appliance` is <stage>-<region>, set through external
  # labels on remote_write, so it can never tell two boxes in one region apart,
  # and grouping by it alone would let a healthy sibling mask a dead cAdvisor
  # through the `unless` above. Prometheus reads an absent label as empty, so
  # this groups exactly as `by (appliance)` would until the host's Alloy sets
  # node on the cAdvisor scrape, and becomes per box by itself on the day it
  # does. No second edit, and nothing to remember.
  #
  # The gate cannot move early the same way. The host scrape already carries
  # node, so joining on it now would match an empty string against a real one,
  # find nothing, and leave this rule silently Normal for ever -- the same class
  # of fault the rule exists to catch. It stays region-wide, which with two
  # boxes means a live sibling holds it open; that is a far smaller gap than a
  # masked detection, and the case it softens is a box entirely dead, which the
  # node rule already covers.
  rule {
    name           = "Appliance container telemetry has stopped"
    condition      = "C"
    for            = "5m"
    no_data_state  = "OK"
    exec_err_state = "Alerting"

    annotations = {
      summary          = "cAdvisor has stopped reporting on {{ $labels.appliance }}"
      description      = "No container metrics are arriving from this appliance, so nothing is watching its containers: \"Appliance container is not running\" gates itself off while cAdvisor is dark and will not fire however many containers stop. Treat this as the containers being unwatched rather than as a missing graph."
      runbook_url      = "https://github.com/fil-forge/infra-nodes/blob/main/docs/RUNBOOK.md#when-something-is-wrong"
      dashboard_url    = "${local.regions_dashboard}&viewPanel=21"
      __dashboardUid__ = "forge-regions"
      __panelId__      = "21"
    }

    labels = {
      team_name = "forge"
      component = "appliance"
      stage     = local.appliance_stage_label
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
        refId        = "A"
        instant      = false
        range        = true
        legendFormat = "{{appliance}}"
        expr         = <<-PROMQL
          (
            max by (appliance, node) (
              up{${local.cadvisor_matcher}} == bool 0
            )
            or
            (
              max by (appliance, node) (
                present_over_time(up{${local.cadvisor_matcher}}[24h])
              )
              unless
              max by (appliance, node) (
                present_over_time(up{${local.cadvisor_matcher}}[5m])
              )
            )
          )
          and on (appliance)
          max by (appliance) (
            present_over_time(up{${local.appliance_matcher}}[5m])
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

# The appliance failures that mean an outage rather than a degradation, in their
# own group at 60s for the reason the containers group gives: at the 300s the
# other appliance rules run at, evaluation alone can use up a five-minute budget.
# Every rule here is severity = "critical", which is what production routing
# keys on to page rather than notify.
resource "grafana_rule_group" "appliance_outages" {
  name             = "Forge Regions outages"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 60

  # OpenBao cannot unseal, so nothing on the node can read its secrets. The
  # node auto-unseals through the transit key at Central, which it reaches with
  # the seal token, so an expired or revoked token, a missing transit key or an
  # unreachable Central all end here (infra-nodes
  # docs/runbook/recover-expired-unseal-token.md).
  #
  # The signal is OpenBao's own retry loop. When unsealing with stored keys
  # fails it logs at WARN
  #
  #   failed to unseal core: error=...
  #
  # and tries again five seconds later, for as long as the failure lasts
  # (openbao command/server.go, runUnseal, at v2.6.2, the version the nodes
  # pin), so a sealed node writes a line every five seconds. The same loop
  # treats only a failed declarative self-init as fatal, and the nodes
  # initialise with `bao operator init` instead, so the WARN line is the one to
  # match.
  #
  # An OpenBao that was started but never initialised fails the same way, with
  # "is the server initialized?" in the error, so a region whose provisioning
  # stops between starting OpenBao and initialising it fires this too. It is
  # sealed all the same, and nothing on the node works until it is fixed.
  #
  # A one-minute window and `for` = 2m keep a single failed attempt during a
  # restart from firing: it falls out of the window before two minutes of
  # pending can accrue, while the five-second loop keeps every window full.
  # Detection is about three minutes from the first failure, inside the five
  # FIL-1164 asks for.
  #
  # What this does not see: a node sealed by hand with `bao operator seal`,
  # which logs "vault is sealed" once and does not retry. Every restart logs
  # that same line on the way down, so it cannot tell the two apart.
  #
  # no_data_state is OK for the reason the other log rules give: count_over_time
  # returns a series only for a node that logged the line. An instant query, so
  # no reduce stage.
  rule {
    name           = "OpenBao cannot unseal"
    condition      = "B"
    for            = "2m"
    no_data_state  = "OK"
    exec_err_state = "Error"

    annotations = {
      summary     = "OpenBao on {{ $labels.node }} ({{ $labels.region }}) is sealed and failing to unseal"
      description = "OpenBao has been logging \"failed to unseal core\" for two minutes. It unseals through the transit key at Central, so the seal token has expired or been revoked, the transit key is missing, or Central is unreachable from the node; if the error asks whether the server is initialized, provisioning stopped before `bao operator init`. Nothing on the node can read its secrets until it unseals. Read the error in `docker logs filone-openbao`, then follow the expired unseal token runbook."
      runbook_url = "https://github.com/fil-forge/infra-nodes/blob/main/docs/runbook/recover-expired-unseal-token.md"
    }

    labels = {
      team_name = "forge"
      component = "appliance"
      stage     = local.appliance_stage_label
      severity  = "critical"
    }

    data {
      ref_id         = "A"
      datasource_uid = var.loki_datasource_uid

      relative_time_range {
        from = 60
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
              {${local.openbao_log_matcher}}
                |= "failed to unseal core"
              [1m]
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

  # A site failing most of what it answers: the outage tier of "Appliance 5xx
  # rate too high", which stays as the warning. Split by host for the same
  # reason, so Ingot's site and Piri's are judged apart; Ingot exports no HTTP
  # metrics of its own, so Caddy's view of its site is its error rate. A 502 here
  # is Caddy failing to reach the upstream.
  #
  # Half of requests is chosen, not derived, like the warning's 5%: high enough
  # that a deploy's restart cannot reach it, and low enough that a site serving
  # only errors to one client and successes to another still trips it. The
  # window is three minutes rather than five because Caddy is scraped every
  # minute and rate() needs two samples, and `for` = 2m keeps detection near
  # five minutes.
  #
  # The gate is a count of failed requests, at least five in the window, not
  # the warning rule's rate floor. A floor in requests per second hides a quiet
  # site that is failing everything, and a busy one whose clients back off once
  # it fails; five errors in three minutes is still enough to keep a single
  # failed request on an idle site from paging. A site whose clients stop
  # sending altogether produces no errors to count, and nothing here sees it.
  #
  # no_data_state is OK: a site with no 5xx produces no series on the
  # numerator's side, so an empty result is the healthy state. An instant query,
  # so no reduce stage.
  rule {
    name           = "Appliance site is failing most requests"
    condition      = "B"
    for            = "2m"
    no_data_state  = "OK"
    exec_err_state = "Error"

    annotations = {
      summary          = "{{ $labels.host }} on {{ $labels.node }} is returning 5xx for more than half of its requests"
      description      = "Caddy has answered more than half of this site's requests with a 5xx for two minutes. A 502 is Caddy failing to reach the upstream, so check the container is running and healthy; a 500 came from Piri or Ingot itself, so read its log. Split by code and handler: sum by (code, handler) (rate(caddy_http_request_duration_seconds_count{host=\"{{ $labels.host }}\", code=~\"5..\"}[3m]))."
      runbook_url      = "https://github.com/fil-forge/infra-nodes/blob/main/docs/RUNBOOK.md#when-something-is-wrong"
      dashboard_url    = "${local.regions_dashboard}&viewPanel=14"
      __dashboardUid__ = "forge-regions"
      __panelId__      = "14"
    }

    labels = {
      team_name = "forge"
      component = "appliance"
      stage     = local.appliance_stage_label
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
            sum by (appliance, region, node, host) (
              rate(caddy_http_request_duration_seconds_count{${local.caddy_matcher}, code=~"5.."}[3m])
            )
            /
            sum by (appliance, region, node, host) (
              rate(caddy_http_request_duration_seconds_count{${local.caddy_matcher}}[3m])
            )
          )
          and
          sum by (appliance, region, node, host) (
            increase(caddy_http_request_duration_seconds_count{${local.caddy_matcher}, code=~"5.."}[3m])
          ) >= 5
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
          evaluator = { type = "gt", params = [0.5] }
        }]
      })
    }
  }
}

# Trace volume, as a nudge rather than an alarm. Nothing else here would say
# that a change -- a new span on a frequent code path, say -- has raised it, so
# this watches the rate of spans Grafana Cloud reports receiving. That rate is
# a proxy for volume: spans that grow larger without growing more numerous do
# not move it. It covers the whole stack, and the stack is shared (main.tf), so
# FilOne's spans count too; it cannot say whose they are, but span names in
# Tempo can.
#
# Everything about it is set to stay quiet:
#
#   - It averages the rate over six hours and needs that average over the
#     threshold for an hour more, so a burst never fires it, and it evaluates
#     every fifteen minutes because nothing about it is urgent.
#   - severity is info, so a route in the policy tree can send it somewhere
#     quieter than the warnings; until one does, it goes wherever the forge
#     route sends everything else.
#
# What it does not stay quiet about is being broken. no_data_state is NoData
# and exec_err_state is Error, because a rule on the wrong data source, or on a
# metric Grafana has renamed, would otherwise look exactly like one with
# nothing to report. Before setting the variables, run the expression below in
# Explore against that data source and check it returns one series.
#
# It exists only once usage_datasource_uid and trace_spans_alert_threshold are
# both set, so this merges as nothing. Before setting them, forge-terraform
# also needs datasources:query on grafanacloud-usage, for the reason the header
# of this file gives.
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
    no_data_state  = "NoData"
    exec_err_state = "Error"

    annotations = {
      summary     = "The stack has received {{ humanize $values.A.Value }} spans per second on average over six hours, above the threshold of ${var.trace_spans_alert_threshold}"
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
          avg_over_time(sum(grafanacloud_traces_instance_spans_received_total:rate5m)[6h:5m])
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
