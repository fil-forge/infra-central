# Central's databases: prod's Aurora clusters and staging's RDS instance
# (FIL-1291). Database CPU is in "Forge capacity", with the other headroom
# rules. The matchers are rds_matcher and rds_stage_regex in
# alerts_capacity.tf, which cover both shapes and the pandora cluster.
#
# Every rule has the capacity rules' shape, one instant query and one
# threshold, so they are a list rendered by the same kind of dynamic block.
# New rules go at the end of the list, because the provider keeps each rule's
# uid by its position.
locals {
  database_rules = [
    {
      # A failover is an instance that was a reader becoming the writer. Only
      # readers publish AuroraReplicaLag, so that is an instance with a lag
      # series in the last half hour, none in the last five minutes, and an
      # EngineUptime series now, which tells it from a reader that was removed
      # or is restarting. This does not depend on whether the promoted
      # instance restarts, which AWS does not document for Aurora PostgreSQL.
      #
      # Warning, not critical: Aurora has already recovered by the time this
      # fires, and if the services had not reconnected "Service has no healthy
      # hosts" and the 5xx rules would say so. What is left is finding out why,
      # and checking the old writer came back as a reader, because until it
      # does the cluster has nothing to fail over to. It fires for about half
      # an hour, then resolves on its own. A single-instance cluster has no
      # reader, so it never fires there.
      name      = "Central database failed over"
      for       = "5m"
      operator  = "gt"
      threshold = 0
      labels    = merge(local.central_labels, { severity = "warning" })
      annotations = {
        summary     = "{{ $labels.instance }} on {{ $labels.stage }} was a reader and is now its cluster's writer"
        description = "The Aurora cluster has failed over to {{ $labels.instance }} in the last half hour. Find out why from the cluster's RDS events, and check that the old writer came back as a reader: until it does, the cluster has no failover target."
        runbook_url = "${local.central_runbook}#central-database-failed-over"
      }
      expr = <<-PROMQL
        count by (stage, instance) (
          label_replace(
            label_replace(
              (
                last_over_time(aws_rds_aurora_replica_lag_maximum{${local.rds_matcher}}[30m])
                unless on (dimension_DBInstanceIdentifier)
                last_over_time(aws_rds_aurora_replica_lag_maximum{${local.rds_matcher}}[5m])
              )
              and on (dimension_DBInstanceIdentifier)
              last_over_time(aws_rds_engine_uptime_minimum{${local.rds_matcher}}[5m]),
              "instance", "$1", "dimension_DBInstanceIdentifier", "(.*)"
            ),
            "stage", "$1", "dimension_DBInstanceIdentifier", "${local.rds_stage_regex}"
          )
        )
      PROMQL
    },
    {
      # AuroraReplicaLag is in milliseconds, and prod's reader runs at about
      # 20. The services read only from the writer, so a lagging reader serves
      # nobody stale data; what it costs is a failover target that comes up
      # behind. Hence a warning, and a threshold fifty times the usual lag.
      name      = "Central database reader lag is high"
      for       = "10m"
      operator  = "gt"
      threshold = 1000
      labels    = merge(local.central_labels, { severity = "warning" })
      annotations = {
        summary     = "Reader {{ $labels.instance }} on {{ $labels.stage }} is more than a second behind its writer"
        description = "The Aurora reader's replica lag has been over 1,000 ms for ten minutes. A failover to it now would come up behind. Check the writer's write load and the reader's CPU and memory."
        runbook_url = "${local.central_runbook}#central-database-reader-lag-is-high"
      }
      expr = <<-PROMQL
        max by (stage, instance) (
          label_replace(
            label_replace(
              aws_rds_aurora_replica_lag_maximum{${local.rds_matcher}},
              "instance", "$1", "dimension_DBInstanceIdentifier", "(.*)"
            ),
            "stage", "$1", "dimension_DBInstanceIdentifier", "${local.rds_stage_regex}"
          )
        )
      PROMQL
    },
    {
      # An RDS instance, so staging's: Aurora publishes no FreeStorageSpace,
      # because its cluster volume grows by itself. Storage autoscaling grows
      # an RDS instance once less than 10% is free, up to max_allocated_storage
      # in modules/platform/database, and waits six hours between steps. On
      # staging's 20 GiB that step starts at 2 GiB free, so 1 GiB for fifteen
      # minutes means autoscaling is not keeping up or has reached its ceiling.
      # Critical: a full instance stops taking writes.
      name      = "Central database free storage low"
      for       = "15m"
      operator  = "lt"
      threshold = 1073741824
      labels    = local.central_labels
      annotations = {
        summary     = "{{ $labels.instance }} on {{ $labels.stage }} has less than 1 GiB of storage free"
        description = "The RDS instance has had less than 1 GiB free for fifteen minutes. Storage autoscaling has not kept up or has reached max_allocated_storage. A full instance stops taking writes."
        runbook_url = "${local.central_runbook}#central-database-free-storage-low"
      }
      expr = <<-PROMQL
        min by (stage, instance) (
          label_replace(
            label_replace(
              aws_rds_free_storage_space_minimum{${local.rds_matcher}},
              "instance", "$1", "dimension_DBInstanceIdentifier", "(.*)"
            ),
            "stage", "$1", "dimension_DBInstanceIdentifier", "${local.rds_stage_regex}"
          )
        )
      PROMQL
    },
    {
      # An Aurora instance's local storage, which holds temporary files and
      # logs; the data is on the cluster volume. Its size is fixed by the
      # instance class, about 31 GiB free on prod's db.r8g.large, so 3 GiB is
      # about a tenth of it. Critical: queries that spill to disk fail once it
      # is full.
      name      = "Central database local storage low"
      for       = "15m"
      operator  = "lt"
      threshold = 3221225472
      labels    = local.central_labels
      annotations = {
        summary     = "{{ $labels.instance }} on {{ $labels.stage }} has less than 3 GiB of local storage free"
        description = "The Aurora instance has had less than 3 GiB of local storage free for fifteen minutes. Local storage holds temporary files and logs, so a query that sorts or hashes more than fits in memory is the usual cause. Queries that spill to disk fail once it is full."
        runbook_url = "${local.central_runbook}#central-database-local-storage-low"
      }
      expr = <<-PROMQL
        min by (stage, instance) (
          label_replace(
            label_replace(
              aws_rds_free_local_storage_minimum{${local.rds_matcher}},
              "instance", "$1", "dimension_DBInstanceIdentifier", "(.*)"
            ),
            "stage", "$1", "dimension_DBInstanceIdentifier", "${local.rds_stage_regex}"
          )
        )
      PROMQL
    },
  ]
}

# 60s because CloudWatch publishes these metrics once a minute, as for
# "Forge Central".
resource "grafana_rule_group" "central_database" {
  name             = "Forge Central database"
  folder_uid       = grafana_folder.alerts.uid
  interval_seconds = 60

  dynamic "rule" {
    for_each = local.database_rules

    content {
      name      = rule.value.name
      condition = "B"
      for       = rule.value.for
      # Staging has no Aurora and prod no RDS instance, so each stage has no
      # data for some of these, and that is the healthy state.
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

        # The failover query reaches back half an hour.
        relative_time_range {
          from = 2400
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
