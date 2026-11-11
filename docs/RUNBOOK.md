# Central alert runbook

What to check first when a Central alert fires. Each section is headed by the rule's name, and the
rule's `runbook_url` links to it. The rules are in `terraform/envs/grafana/`, and
[observability.md](observability.md) lists them, sets out what each `severity` means, and says how
to read a stage's logs and metrics in Grafana. Appliance alerts link to fil-forge/infra-nodes'
`docs/RUNBOOK.md` instead.

Throughout, `<stage>` is the alert's `stage` label and `<service>` its `service` label. A stage's
ECS cluster is `fc-<stage>`, each service in it is `fc-<stage>-<service>`, and each service logs to
the CloudWatch group `/forge-central/<stage>/<service>`, which reaches Grafana as:

```logql
{aws_log_group="/forge-central/<stage>/<service>"}
```

`scripts/tail-logs.sh <stage>` prints the same lines from CloudWatch. The AWS commands below need
credentials for the stage's account: the non-prod account for dev and staging, the prod account for
prod.

## Service has no healthy hosts

The load balancer has no healthy target for the service, so every request to it fails. That
includes a service with no running tasks at all.

Check first: the ECS service's recent events, which say whether tasks are failing to start, failing
their health check, or being stopped.

```bash
aws ecs describe-services --cluster fc-<stage> --services fc-<stage>-<service> \
  --query 'services[0].{running:runningCount,desired:desiredCount,events:events[:10].message}'
```

Then the service's logs, for why a task exited or what its health endpoint (listed in the README's
"What each service needs") is reporting.

- **A deploy just landed:** pin the service's previous digest in the stage's `image_digests` (the
  README's "Deploying a service") and merge.
- **`desired` is 0:** someone scaled it down. Scale it back up, or apply the stage's apps root.
- **The service is `openbao`:** a sealed OpenBao answers its health check with 503, so this is how
  a sealed or unreachable Central OpenBao shows up. With a KMS seal, a sealed instance means it
  could not reach or use its KMS key; its log says which. While it is down, hilt cannot read
  tenant secrets, and an appliance whose OpenBao restarts cannot unseal.

## Service 5xx errors

The service's targets returned more than one 5xx a minute, averaged over five, for ten minutes.
Customers are seeing some failures, but most requests succeed.

Check first: the service's errors in Grafana, which usually name the failing dependency.

```logql
{aws_log_group="/forge-central/<stage>/<service>"} | json | level=~"(?i)error|fatal"
```

Then whether it started with a deploy (the stage's last change to `image_digests`) or with a
dependency: the database rules below, or the service's own dependencies in the README's "What each
service needs". Roll back a bad deploy as in [Service has no healthy hosts](#service-has-no-healthy-hosts).

## Service is failing most requests

More than half of the service's requests in the last five minutes returned a 5xx. This is the
outage tier of [Service 5xx errors](#service-5xx-errors); work through that section, faster.

## Provision Lambda errors

`fc-<stage>-provision` returned errors. It runs during a stage's platform apply, to create the
services' database roles and databases and to initialise OpenBao, so a failure usually fails that
apply too.

Check first: its log, in Grafana or CloudWatch.

```logql
{aws_log_group="/aws/lambda/fc-<stage>-provision"}
```

Then the platform apply that invoked it, which shows the error the Lambda returned. Fix the cause
and re-run the apply.

## Pandora VPN tunnel down

One tunnel of the compatibility server's site-to-site VPN has been down for fifteen minutes, or no
`TunnelState` data has arrived. The other tunnel still carries traffic, so nothing is failing yet,
but the site has no redundancy.

Check first: the VPC console's Site-to-Site VPN connections page, in the AWS account the alert names, which shows
each tunnel's status and the reason it is down. Then the appliance side, as
[pandora-vpn.md](pandora-vpn.md#checking-the-path) describes.

## Pandora VPN both tunnels down

Both tunnels are down, so the compatibility server cannot reach the pandora database. Check as for
[Pandora VPN tunnel down](#pandora-vpn-tunnel-down).

## Service response time is high

The service's targets have taken longer than the threshold, on average, to start answering, for
ten minutes. The threshold is provisional until FIL-1242 sets the latency SLO.

Check first: the service's CPU and memory on the Forge Central dashboard, and the [Central
database CPU high](#central-database-cpu-high) rule, since a slow database slows every service that
uses it. Then the service's logs for slow calls to its dependencies.

## Central service CPU high

The service's tasks have averaged over 80% of their CPU reservation for fifteen minutes. Requests
slow down as they reach it.

Check first: whether traffic rose (the Forge Central dashboard's Request count panel) or the service got slower per
request after a deploy. If it is load, raise the service's `cpu` in the stage's apps sizes and
merge.

## Central service memory high

A task of the service has been above 85% of its memory reservation for fifteen minutes. A task that
reaches 100% is killed.

Check first: whether memory climbs steadily across the service's tasks, which points to a leak, or
rose with traffic. Raise the service's `memory` in the stage's apps sizes and merge. A leak needs
the service fixed as well; restarting the tasks only buys time.

## Central database CPU high

The database instance has been above 80% CPU for fifteen minutes. Every service that uses it slows
down.

Check first: which queries are using it. Performance Insights in the RDS console shows the top SQL
by load. If it is load rather than one bad query, size up `db_instance_class` in the stage's
platform root.

## Central database failed over

One of prod's Aurora readers became its cluster's writer in the last half hour. Aurora recovered by
itself: if the services had not reconnected, [Service has no healthy hosts](#service-has-no-healthy-hosts)
or the 5xx rules would also be firing.

Check first: why it failed over, from the cluster's RDS events.

```bash
aws rds describe-events --source-type db-cluster --source-identifier <cluster> --duration 120
```

`<cluster>` is the instance name without its `-<n>` suffix: `fc-prod` or `fc-prod-pandora-db`.

Then that the old writer came back as a reader. Until it does, the cluster has nothing to fail over
to.

```bash
aws rds describe-db-clusters --db-cluster-identifier <cluster> \
  --query 'DBClusters[0].DBClusterMembers[].{instance:DBInstanceIdentifier,writer:IsClusterWriter}'
aws rds describe-db-instances --db-instance-identifier <old writer> \
  --query 'DBInstances[0].DBInstanceStatus'
```

## Central database reader lag is high

An Aurora reader has been more than a second behind its writer for ten minutes. The services read
only from the writer, so nobody is served stale data, but a failover to this reader now would come
up behind.

Check first: the writer's write load and the reader's CPU and memory, in the RDS console's
monitoring tab for each instance. A reader smaller than or busier than its writer falls behind
under heavy writes.

## Central database free storage low

Staging's RDS instance has had less than 1 GiB free for fifteen minutes. Storage autoscaling grows
it once less than 10% is free, so either it has reached `max_allocated_storage` or it is waiting out
the six hours autoscaling leaves between steps. A full instance stops taking writes.

Check first: the instance's allocated storage against its ceiling.

```bash
aws rds describe-db-instances --db-instance-identifier fc-<stage> \
  --query 'DBInstances[0].{allocated:AllocatedStorage,max:MaxAllocatedStorage,status:DBInstanceStatus}'
```

RDS refuses any storage change, autoscaling's included, for six hours after the last one or until
the instance leaves `storage-optimization`, whichever is longer. The query above shows the status,
and the instance's events show when storage last changed:

```bash
aws rds describe-events --source-type db-instance --source-identifier fc-<stage> --duration 360
```

Inside that window nothing can grow the instance, so free space instead. Find what is filling it:
`pg_database_size` per database, `pg_total_relation_size` per table, and `pg_replication_slots` for
a slot that has stopped advancing and is holding WAL. Only `DROP` or `TRUNCATE` gives space back at
once. `DELETE` and a plain `VACUUM` only make it reusable inside the table, and `VACUUM FULL` needs
about the table's size free while it runs, which a nearly full instance may not have. A stale
replication slot is freed by dropping it with `pg_drop_replication_slot`.

Outside that window:

- **At the ceiling:** raise `max_allocated_storage` in `modules/platform/database` and apply the
  stage's platform root. The platform root does not pass it through, so the default changes for dev
  too.
- **Below the ceiling:** grow it now, then bring the platform root's `db_allocated_storage` up to
  match. RDS rejects an increase of less than 10% of the current allocation.

  ```bash
  aws rds modify-db-instance --db-instance-identifier fc-<stage> \
    --allocated-storage <GiB> --apply-immediately
  ```

## Central database local storage low

An Aurora instance has had less than 3 GiB of local storage free for fifteen minutes. Local storage
holds temporary files and logs, not the data, and its size is fixed by the instance class. Queries
that spill to disk fail once it is full.

Check first: which queries are writing temporary files. Performance Insights shows the top SQL, and
`pg_stat_database.temp_bytes` shows the volume. A query that sorts or hashes more than fits in
`work_mem` is the usual cause. If the load is legitimate, size up `db_instance_class`, which brings
more local storage with it.
