# Finding a stage's logs and metrics in Grafana

Every Forge Central stage ships its CloudWatch logs and its AWS service metrics to the Filecoin
Foundation Grafana Cloud stack. This page says what arrives, under which labels, and the queries
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

Everything Forge Central ships from one AWS account, across stages:

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
sum by (dimension_TargetGroup) (aws_applicationelb_httpcode_target_5xx_count_sum{dimension_LoadBalancer=~"app/fc-dev.*"})
```

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

Each Firehose reports whether Grafana accepted its batches. A value below one for any stream
means lines or samples are being held back:

```promql
aws_firehose_delivery_to_http_endpoint_success_average{dimension_DeliveryStreamName=~"fc-.*-logs|forge-central-metrics"}
```

A batch Grafana refuses is written to the `forge-central-firehose-backup-<account id>-<region>` bucket under
a prefix named for the stream, and the reason is in the `/forge-central/firehose` CloudWatch log
group, one stream per Firehose. An empty bucket is the healthy state.

From the AWS side, the authoritative list of what a stage forwards:

```bash
aws logs describe-subscription-filters --region us-east-2 \
  --query "subscriptionFilters[].[logGroupName,destinationArn]" --output table
aws cloudwatch list-metric-streams --region us-east-2
```
