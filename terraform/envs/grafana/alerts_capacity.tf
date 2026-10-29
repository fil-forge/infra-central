# CPU and memory headroom, for Central and the appliances (FIL-1214). Each rule
# warns while there is still time to scale up, so every one is a warning: none
# of them is an outage yet.
#
# Every rule has the same shape -- one instant query, one threshold -- so they
# are a list rendered by a dynamic block rather than seven copies of it. The
# locals they read (matchers, dashboards, query_defaults) are in alerts.tf.
locals {
  # The ECS service name is fc-<stage>-<service>. The stage comes from the
  # cluster name instead, so it is a label of its own for grouping and links.
  ecs_matcher       = "dimension_ClusterName=~\"fc-(${local.stages})\""
  ecs_service_regex = "fc-(?:${local.stages})-(.*)"
  ecs_stage_regex   = "fc-(${local.stages})"

  # Dev and staging run one RDS instance named fc-<stage>; prod's Aurora
  # instances are fc-prod-<n>, and the compatibility server's are
  # fc-<stage>-pandora-db-<n>.
  rds_matcher     = "dimension_DBInstanceIdentifier=~\"fc-(${local.stages})(-pandora-db)?(-[0-9]+)?\""
  rds_stage_regex = "fc-(${local.stages})(?:-pandora-db)?(?:-[0-9]+)?"

  # cAdvisor reports a usage series with a cpu="total" label and spec series
  # without it, so each side is summed to the same labels before dividing.
  container_group = "appliance, region, node, service_name"
  host_group      = "appliance, region, node"

  central_labels = {
    team_name = "forge"
    component = "central"
    severity  = "warning"
  }

  appliance_labels = {
    team_name = "forge"
    component = "appliance"
    stage     = local.appliance_stage_label
    severity  = "warning"
  }

  appliance_runbook = "https://github.com/fil-forge/infra-nodes/blob/main/docs/RUNBOOK.md#when-something-is-wrong"

  # The host is shared with the provider's own workloads, so its load may not
  # be ours. Said in both host rules' descriptions.
  shared_host_note = "The host also runs workloads that are not Forge's, so check the Containers panel to see whether ours are the ones using it."

  capacity_rules = [
    {
      name      = "Central service CPU high"
      for       = "15m"
      operator  = "gt"
      threshold = 80
      labels    = local.central_labels
      annotations = {
        summary          = "{{ $labels.service }} on {{ $labels.stage }} is above 80% of its CPU"
        description      = "Average CPU across the service's tasks has been above 80% of the task's reservation for fifteen minutes. Raise its cpu in the stage's apps sizes before requests start to slow."
        dashboard_url    = "${local.central_dashboard}&var-service={{ $labels.service }}&viewPanel=1"
        __dashboardUid__ = "forge-central"
        __panelId__      = "1"
      }
      expr = <<-PROMQL
        max by (stage, service) (
          label_replace(
            label_replace(
              aws_ecs_cpuutilization_average{${local.ecs_matcher}},
              "service", "$1", "dimension_ServiceName", "${local.ecs_service_regex}"
            ),
            "stage", "$1", "dimension_ClusterName", "${local.ecs_stage_regex}"
          )
        )
      PROMQL
    },
    {
      # The maximum rather than the average: one task over its limit is killed
      # however much room the others have.
      name      = "Central service memory high"
      for       = "15m"
      operator  = "gt"
      threshold = 85
      labels    = local.central_labels
      annotations = {
        summary          = "{{ $labels.service }} on {{ $labels.stage }} is above 85% of its memory"
        description      = "A task of this service has been above 85% of its memory reservation for fifteen minutes. A task that reaches 100% is killed. Raise its memory in the stage's apps sizes."
        dashboard_url    = "${local.central_dashboard}&var-service={{ $labels.service }}&viewPanel=12"
        __dashboardUid__ = "forge-central"
        __panelId__      = "12"
      }
      expr = <<-PROMQL
        max by (stage, service) (
          label_replace(
            label_replace(
              aws_ecs_memory_utilization_maximum{${local.ecs_matcher}},
              "service", "$1", "dimension_ServiceName", "${local.ecs_service_regex}"
            ),
            "stage", "$1", "dimension_ClusterName", "${local.ecs_stage_regex}"
          )
        )
      PROMQL
    },
    {
      # No dashboard panel shows database CPU yet, so no link.
      name      = "Central database CPU high"
      for       = "15m"
      operator  = "gt"
      threshold = 80
      labels    = local.central_labels
      annotations = {
        summary     = "{{ $labels.instance }} on {{ $labels.stage }} is above 80% CPU"
        description = "The database instance has been above 80% CPU for fifteen minutes. Size up its instance class in the stage's platform root."
      }
      expr = <<-PROMQL
        max by (stage, instance) (
          label_replace(
            label_replace(
              aws_rds_cpuutilization_average{${local.rds_matcher}},
              "instance", "$1", "dimension_DBInstanceIdentifier", "(.*)"
            ),
            "stage", "$1", "dimension_DBInstanceIdentifier", "${local.rds_stage_regex}"
          )
        )
      PROMQL
    },
    {
      # A container without a limit reports 0, which `> 0` drops, so this only
      # watches containers whose Compose service sets mem_limit.
      name      = "Appliance container memory high"
      for       = "15m"
      operator  = "gt"
      threshold = 0.85
      labels    = local.appliance_labels
      annotations = {
        summary          = "{{ $labels.service_name }} on {{ $labels.node }} is above 85% of its memory limit"
        description      = "The container's working set has been above 85% of its mem_limit for fifteen minutes. A container that reaches its limit is killed. Raise mem_limit in the node's Compose file."
        runbook_url      = local.appliance_runbook
        dashboard_url    = "${local.regions_dashboard}&viewPanel=21"
        __dashboardUid__ = "forge-regions"
        __panelId__      = "21"
      }
      expr = <<-PROMQL
        sum by (${local.container_group}) (container_memory_working_set_bytes{${local.container_matcher}})
        /
        (sum by (${local.container_group}) (container_spec_memory_limit_bytes{${local.container_matcher}}) > 0)
      PROMQL
    },
    {
      # cAdvisor publishes a quota only for a container with a CPU limit, so
      # this too only watches containers whose Compose service sets cpus.
      name      = "Appliance container CPU high"
      for       = "15m"
      operator  = "gt"
      threshold = 0.8
      labels    = local.appliance_labels
      annotations = {
        summary          = "{{ $labels.service_name }} on {{ $labels.node }} is above 80% of its CPU limit"
        description      = "The container has used more than 80% of its cpus limit for fifteen minutes. At the limit it is throttled and slows down. Raise cpus in the node's Compose file."
        runbook_url      = local.appliance_runbook
        dashboard_url    = "${local.regions_dashboard}&viewPanel=21"
        __dashboardUid__ = "forge-regions"
        __panelId__      = "21"
      }
      expr = <<-PROMQL
        sum by (${local.container_group}) (rate(container_cpu_usage_seconds_total{${local.container_matcher}}[5m]))
        /
        (
          sum by (${local.container_group}) (container_spec_cpu_quota{${local.container_matcher}})
          /
          sum by (${local.container_group}) (container_spec_cpu_period{${local.container_matcher}})
        )
      PROMQL
    },
    {
      name      = "Appliance host memory low"
      for       = "15m"
      operator  = "lt"
      threshold = 0.1
      labels    = local.appliance_labels
      annotations = {
        summary          = "{{ $labels.appliance }} has less than 10% of its memory available"
        description      = "{{ $labels.node }} has had less than 10% of its memory available for fifteen minutes, so its containers are close to being killed. ${local.shared_host_note}"
        runbook_url      = local.appliance_runbook
        dashboard_url    = "${local.regions_dashboard}&viewPanel=5"
        __dashboardUid__ = "forge-regions"
        __panelId__      = "5"
      }
      expr = <<-PROMQL
        min by (${local.host_group}) (
          node_memory_MemAvailable_bytes{${local.appliance_matcher}}
          / node_memory_MemTotal_bytes{${local.appliance_matcher}}
        )
      PROMQL
    },
    {
      # 30m rather than 15m: a busy host's CPU swings more than its memory.
      name      = "Appliance host CPU high"
      for       = "30m"
      operator  = "gt"
      threshold = 0.9
      labels    = local.appliance_labels
      annotations = {
        summary          = "{{ $labels.appliance }} is above 90% CPU"
        description      = "{{ $labels.node }} has been more than 90% busy for thirty minutes, so its containers are competing for CPU. ${local.shared_host_note}"
        runbook_url      = local.appliance_runbook
        dashboard_url    = "${local.regions_dashboard}&viewPanel=4"
        __dashboardUid__ = "forge-regions"
        __panelId__      = "4"
      }
      expr = <<-PROMQL
        1 - avg by (${local.host_group}) (
          rate(node_cpu_seconds_total{mode="idle", ${local.appliance_matcher}}[5m])
        )
      PROMQL
    },
  ]
}

resource "grafana_rule_group" "capacity" {
  name             = "Forge capacity"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 300

  dynamic "rule" {
    for_each = local.capacity_rules

    content {
      name      = rule.value.name
      condition = "B"
      for       = rule.value.for
      # Absent data is the scrape and reporting rules' to raise, not these.
      no_data_state  = "OK"
      exec_err_state = "Error"

      annotations = rule.value.annotations
      labels      = rule.value.labels

      notification_settings {
        policy = local.forge_policy
      }

      data {
        ref_id         = "A"
        datasource_uid = var.prometheus_datasource_uid

        relative_time_range {
          from = 600
          to   = 0
        }

        model = jsonencode(merge(local.query_defaults, {
          refId   = "A"
          instant = true
          range   = false
          expr    = rule.value.expr
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
            evaluator = { type = rule.value.operator, params = [rule.value.threshold] }
          }]
        })
      }
    }
  }
}
