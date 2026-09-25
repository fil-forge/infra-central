# Finding a stage's logs and metrics in Grafana

Every Forge Central stage the deploy workflow applies ships its CloudWatch logs and its AWS
service metrics to the Filecoin Foundation Grafana Cloud stack. A personal sandbox stage applied
with `enable_log_forwarding = false` ships no logs, and its metrics arrive only because the
account's metric stream cannot tell stages apart. This page says what arrives, under which labels, and the queries
that find it. How the pipeline is built and why it is shaped that way is in [the telemetry
decision](decisions/2026-09-grafana-telemetry.md).

## What ships

**Logs.** Every line the six services, OpenBao and the provision Lambda write to CloudWatch, within
about a minute of being written. The CloudWatch groups stay as they are, thirty days deep, for
`scripts/tail-logs.sh` and the deploy workflow's diagnose jobs.

**Metrics.** Everything AWS publishes for the stage's ECS services, load balancer, RDS instance,
NAT gateway and the telemetry Firehoses themselves. The provision Lambda's and the DynamoDB tables'
metrics arrive too, through the metric stream
[fil-one/infra](https://github.com/fil-one/fil-one/tree/main/infra) runs in the same account.

**Not shipped.** Application metrics, since not all services expose a `/metrics` endpoint yet;
traces; VPC flow logs; ALB access logs. The last two stay in CloudWatch and S3 respectively. Follow-up work:

- [FIL-1152](https://linear.app/filecoin-foundation/issue/FIL-1152) Ship metrics from swarf, delegator and piri-signing-service to Grafana
- [FIL-1143](https://linear.app/filecoin-foundation/issue/FIL-1143) Instrument Hilt to provide useful telemetry
- [FIL-1144](https://linear.app/filecoin-foundation/issue/FIL-1144) Instrument Sprue to provide useful telemetry

## Where to look

| Signal  | Data source                            | Query language |
| ------- | -------------------------------------- | -------------- |
| Logs    | `grafanacloud-filecoinfoundation-logs` | LogQL          |
| Metrics | `grafanacloud-filecoinfoundation-prom` | PromQL         |

Both are in Explore. Pick the data source, paste a query below, set the time range.

## Dashboards

Two dashboards read these two data sources, in the `Forge (managed in git)`
folder. Both are parameterised by stage, and the second by region as well:

| Dashboard                                                          | Covers           |
| ------------------------------------------------------------------ | ---------------- |
| [Forge Central](https://filecoinfoundation.grafana.net/d/forge-central)     | Central services |
| [Forge Regions](https://filecoinfoundation.grafana.net/d/forge-regions)     | Appliances       |

The very first apply of that root is a two-credential job and has its own page:
[first-grafana-apply.md](first-grafana-apply.md).

They are committed, not edited in place: the JSON is in
`terraform/envs/grafana/dashboards/` and applied from that root. A panel changes
by pull request, and an export taken from the UI goes through
`scripts/normalise-dashboard.sh` first. Why it is arranged that way, and what
else in the stack the root is deliberately not allowed to touch, is in
[decisions/2026-09-dashboards-in-git.md](decisions/2026-09-dashboards-in-git.md).

Alert rules live in the same root, in a **separate** folder — `Forge alerts
(managed in git)` — which grants Editor and Viewer `View` only, because a rule
edited in the UI would be silently reverted by the next apply. The dashboards
are the other way round: editable in the UI, reviewed afterwards. `folders.tf`
sets out the three ownership models.

Each rule carries `team = "forge"`, and a route in the notification policy tree
— which is maintained in the UI, not here — is what turns that label into a
channel. Adding that one route is a manual step nobody has done yet, so **the
rules below evaluate but reach no one** until it exists.

| Rule                                | Group                     | Source            | Ticket   |
| ----------------------------------- | ------------------------- | ----------------- | -------- |
| Service has no healthy hosts        | Forge Central             | ALB, CloudWatch   | FIL-1151 |
| Service 5xx errors                  | Forge Central             | ALB, CloudWatch   | FIL-1207 |
| Provision Lambda errors             | Forge Central             | Lambda, CloudWatch| FIL-1151 |
| Appliance has stopped reporting     | Forge appliances          | deploy stamp      | FIL-1163 |
| Appliance free disk space below 40% | Forge appliances          | node exporter     | FIL-1209 |
| Appliance container is not running  | Forge appliance containers| cAdvisor, staging | FIL-1163 |

The notes at the end of `terraform/envs/grafana/alerts.tf` say what each alert
that is *not* written is waiting on — a threshold nobody has agreed, a decision
nobody has taken, or a metric nothing publishes.

## Logs

One service:

```logql
{aws_log_group="/forge-central/dev/hilt"}
```

Everything a stage writes, services and OpenBao and the Lambda together:

```logql
{service_name="forge-central-dev"}
```

Only errors, across the stage:

```logql
{service_name="forge-central-dev"} | json | level=~"(?i)error|fatal"
```

Everything Forge Central ships from the non-prod account, across stages (the constants module
lists both account ids):

```logql
{account_id="654654381893", aws_log_group=~"/forge-central/.*"}
```

The provision Lambda, which uses the AWS-defined log group format:

```logql
{aws_log_group="/aws/lambda/fc-dev-provision"}
```

### Log labels

| Label            | Example                   | Set by                                                                  |
| ---------------- | ------------------------- | ----------------------------------------------------------------------- |
| `aws_log_group`  | `/forge-central/dev/hilt` | Grafana, from the CloudWatch envelope. The one that names a service.    |
| `service_name`   | `forge-central-dev`       | Loki, derived from `service`. One value per stage.                      |
| `service`        | `forge-central-dev`       | The stage's Firehose.                                                   |
| `environment`    | `dev`                     | The stage's Firehose.                                                   |
| `account_id`     | `654654381893`            | Grafana, from the envelope.                                             |
| `origin`, `job`  | `cloudwatch`, `cloud/aws` | Grafana. Every Firehose-delivered line carries both.                    |
| `detected_level` | `info`                    | Loki, parsed from the line.                                             |
| `aws_log_stream` | `hilt/hilt/3f9c…`         | Grafana. Structured metadata, so it is shown on a line but not indexed. |

A few lines per stage carry no `aws_log_group` and read
`CWL CONTROL MESSAGE: Checking health of destination Firehose.` CloudWatch Logs sends one when a
subscription filter is created and again on occasion afterwards; they are not from any service and
can be ignored.

`service_name` is per stage rather than per service because one Firehose carries the whole stage
and Loki derives that label from the Firehose's fixed attributes. Select a service by
`aws_log_group`; the group name already carries the stage, so no second matcher is needed.
Appliance logs, shipped by Alloy from the node, use `service_name=appliance-<stage>-<region>-<service>`
and `node` and `region` labels instead.

## Metrics

Metric names follow `aws_<namespace>_<metric>_<statistic>`, with the CloudWatch name in snake case
and one series per statistic: `_sum`, `_average`, `_minimum`, `_maximum`, `_sample_count`.
CloudWatch dimensions arrive as labels prefixed `dimension_`, and every series carries
`account_id`, `region` and `namespace`.

CPU across a stage's services:

```promql
aws_ecs_cpuutilization_average{dimension_ClusterName="fc-dev"}
```

Postgres connections on the stage's instance:

```promql
aws_rds_database_connections_average{dimension_DBInstanceIdentifier="fc-dev"}
```

Server errors returned by the stage's services, per target group:

```promql
sum by (dimension_TargetGroup) (aws_applicationelb_httpcode_target_5_xx_count_sum{dimension_LoadBalancer=~"app/fc-dev.*", dimension_AvailabilityZone="", dimension_TargetGroup!=""})
```

Server errors per minute, per service, over a five-minute window:

```promql
sum by (service) (
  label_replace(
    sum_over_time(aws_applicationelb_httpcode_target_5_xx_count_sum{dimension_LoadBalancer=~"app/fc-dev.*", dimension_AvailabilityZone="", dimension_TargetGroup!=""}[5m]),
    "service", "$1", "dimension_TargetGroup", "targetgroup/fc-dev-(.*)/.*"
  )
) / 5
```

The load balancer publishes every HTTP code metric three times: once per availability zone, once
per target group and once for the whole balancer. The two extra matchers keep the per-target-group
series only. CloudWatch publishes a 5xx count only in minutes when a service returned one, so an
empty result means the service returned no server errors in the window. Each sample is one minute's
count, so the query adds samples with `sum_over_time`.

Provision Lambda errors, arriving through fil-one/infra's stream:

```promql
aws_lambda_errors_sum{dimension_FunctionName="fc-dev-provision"}
```

Reads against the delegator's tables, likewise:

```promql
aws_dynamodb_consumed_read_capacity_units_sum{dimension_TableName=~"fc-dev-delegator-.*"}
```

Metric names can be browsed in Explore with the metrics browser, or with a regex against the name
list, `aws_ecs_.*` for example.

### Which label names a stage

| Namespace            | Label that carries the stage                                          |
| -------------------- | --------------------------------------------------------------------- |
| `AWS/ECS`            | `dimension_ClusterName="fc-<stage>"`, `dimension_ServiceName`         |
| `AWS/ApplicationELB` | `dimension_LoadBalancer=~"app/fc-<stage>.*"`, `dimension_TargetGroup` |
| `AWS/RDS`            | `dimension_DBInstanceIdentifier="fc-<stage>"`                         |
| `AWS/NATGateway`     | `dimension_NatGatewayId`; the id is in the platform root's state      |
| `AWS/Lambda`         | `dimension_FunctionName="fc-<stage>-provision"`                       |
| `AWS/DynamoDB`       | `dimension_TableName=~"fc-<stage>-.*"`                                |
| `AWS/Firehose`       | `dimension_DeliveryStreamName="fc-<stage>-logs"`                      |

## Is the pipeline itself healthy

Each Firehose reports how old its oldest undelivered record is. A healthy stream sits at about the
sixty-second buffering interval; a value that keeps climbing means Grafana is refusing batches:

```promql
aws_firehose_delivery_to_http_endpoint_data_freshness_maximum{dimension_DeliveryStreamName=~"fc-.*-logs|forge-central-metrics"}
```

Every `AWS/Firehose` series reaches Grafana through the `forge-central-metrics` stream, that
stream's own freshness included. When Grafana refuses its batches, the series above stops updating
for every stream at once instead of climbing. Read staleness off `forge-central-metrics` alone.
CloudWatch publishes metrics every minute, so that stream always has records and its series goes
stale only when the stream is stuck. A log stream for a quiet stage reports no freshness while it
has nothing to deliver, and the direct CloudWatch lookup below returns no datapoints for it either.
The live reading for the metrics stream is in CloudWatch. Times are UTC in the form
`2026-09-14T13:00:00Z`:

```bash
aws cloudwatch get-metric-statistics --region us-east-2 --namespace AWS/Firehose \
    --metric-name DeliveryToHttpEndpoint.DataFreshness \
    --dimensions Name=DeliveryStreamName,Value=forge-central-metrics \
    --start-time <fifteen minutes ago> --end-time <now> --period 60 --statistics Maximum
```

The success metric counts the delivery requests Grafana accepted per minute. Firehose holds
records for sixty seconds before delivering, so on a quiet stream the requests received in one
minute are often delivered in the next, and a single minute of incoming requests with no success
means nothing. Compare the two over a window longer than the buffer; a stream that keeps receiving
requests while accepting none, window after window, is the same fault seen from the other side:

```promql
sum_over_time(aws_firehose_incoming_put_requests_sum{dimension_DeliveryStreamName="fc-dev-logs"}[10m])
```

```promql
sum_over_time(aws_firehose_delivery_to_http_endpoint_success_sum{dimension_DeliveryStreamName="fc-dev-logs"}[10m])
```

A batch Grafana refuses is written to the `forge-central-firehose-backup-<account id>-<region>` bucket under
a prefix named for the stream, and the reason is in the `/forge-central/firehose` CloudWatch log
group, one stream per Firehose. An empty bucket is the healthy state.

From the AWS side, the authoritative list of what a stage forwards. CloudWatch lists subscription
filters per log group only, so the loop asks each of the stage's groups in turn:

```bash
for group in /aws/lambda/fc-<stage>-provision $(aws logs describe-log-groups --region us-east-2 \
    --log-group-name-prefix /forge-central/<stage>/ \
    --query "logGroups[].logGroupName" --output text); do
  aws logs describe-subscription-filters --region us-east-2 --log-group-name "$group" \
    --query "subscriptionFilters[].[logGroupName,destinationArn]" --output text
done
aws cloudwatch list-metric-streams --region us-east-2
```
