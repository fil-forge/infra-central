# Logs and AWS metrics ship to Grafana Cloud from the bootstrap layer

Every stage's CloudWatch log groups and the AWS metrics for its ECS services, load balancer, RDS
instance, NAT gateway and Firehoses reach the filecoinfoundation Grafana Cloud stack. Logs go
through one Kinesis Data Firehose per stage into Loki. Metrics go through one CloudWatch Metric
Stream per account and region, and its own Firehose, into Prometheus. Where to find what arrives
is in [docs/observability.md](../observability.md).

## The token-bearing resources live in the regional bootstrap root

A Firehose keeps its HTTP endpoint access key as an ordinary attribute, and the AWS provider offers
no write-only variant for it, so the Grafana push token lands in whichever state applies the
Firehose. The stage roots are applied by CI, and the CI plan role is built so a pull request's plan
job can describe infrastructure and read no data. A Firehose in a stage root would put the token
in a state that role reads, and would need the role to read whatever supplies the token at plan
time.

So the Firehoses and the metric stream are in `terraform/modules/telemetry`, called from
`terraform/envs/bootstrap/<account>/<region>/`, which an operator applies from a laptop. The
operator passes the Loki instance id, the Prometheus instance id and an access policy token with
`logs:write` and `metrics:write` as `TF_VAR_grafana_logs_user`, `TF_VAR_grafana_metrics_user` and
`TF_VAR_grafana_push_token`, read from the Forge Central item in the Fil One 1Password vault.
Nothing secret is committed. The CI roles need no new permission:
`logs:*` covers subscription filters and the apply role may already write `fc-*` IAM roles.

The stage roots create only what needs no token. `terraform/modules/platform/log-forwarding` makes
the role CloudWatch Logs assumes, `fc-<stage>-logs-to-firehose`, and computes the Firehose ARN from
the stage, account and region by the name convention `fc-<stage>-logs`, the way a stage derives its
ECR URL rather than reading bootstrap output. Every module that owns a log group takes that pair
and adds a subscription filter. The apps root reads the pair from the platform root's outputs.

A stage exists in one list, `nonprod_stages` in `terraform/modules/shared/constants`. The account
bootstrap root grants the CI roles state access from it and the regional root creates a log
Firehose from it. The CI workflow's matrix names the stages a third time in YAML, which cannot read
a module output.

## The metric stream shares the account with FilOne's

A metric stream ships every metric in the namespaces it names, for every resource in the account
and region. It cannot filter by resource or tag. fil-one/infra already runs a stream in both AWS
accounts naming `AWS/Lambda`, `AWS/ApiGateway`, `AWS/SQS`, `AWS/DynamoDB` and `FilOne`, which means
the provision Lambda's and the delegator's DynamoDB tables' metrics were arriving in Grafana before
this repository shipped anything.

Forge Central's stream names only what FilOne's does not: `AWS/ECS`, `AWS/ApplicationELB`,
`AWS/RDS`, `AWS/NATGateway` and `AWS/Firehose`. Naming Lambda or DynamoDB here would ship every
FilOne Lambda's samples twice, and Grafana Cloud rejects or double-counts a duplicate sample and
bills for it either way.

The alternative was to add the four namespaces to FilOne's stream and create nothing here. One
stream per account is the natural unit and overlap becomes impossible, at the cost of putting a
fil-one pull request and an SST deploy on the path of every Forge Central telemetry change, in a
stack named `filone-infra-staging` whose scope is the sandbox account. Keeping Forge Central's
egress in this repository was worth the coupling that remains: Forge Central's Lambda and DynamoDB
metrics depend on FilOne's stream keeping those two namespaces. The header of
`modules/telemetry/main.tf` says so, and a comment on the include filter in fil-one's
`infra/sst.config.ts` points back here. If that stream is ever removed or narrowed, the two
namespaces move into this module.

`AWS/Firehose` is included so the pipeline reports on itself. Its `DeliveryToHttpEndpoint.Success`
metric dropping below one is the signal that logs or metrics have stopped arriving, and it covers
FilOne's Firehoses in the account as well.

## One log Firehose per stage, labels from the log group

Grafana's Firehose endpoint keeps the CloudWatch log group name as the indexed label
`aws_log_group`, adds `account_id`, `origin` and `job`, stores the log stream as structured
metadata, and turns each `lbl_`-prefixed common attribute the Firehose sends into a label with the
prefix removed. Loki then derives `service_name` from the `service` label. Verified against FilOne
staging's lines before this was built.

Each stage's Firehose sends `lbl_environment=<stage>` and `lbl_service=forge-central-<stage>`. A
service is selected by `aws_log_group` alone. `service_name` is therefore per stage, where the
appliances' Alloy publishes it per service as `appliance-<stage>-<region>-<service>`. One Firehose
per service would have matched that shape at the cost of seven Firehoses per stage, the service list
moving into the constants module, and a bootstrap apply for every new service. A new service is
forwarded today with no bootstrap change, because the subscription filter is created next to the
log group it forwards.

## Scope

AWS-namespace metrics only. Application metrics need a `/metrics` endpoint and a scraper, and are
[FIL-1152](https://linear.app/filecoin-foundation/issue/FIL-1152). Traces are out of scope for the
current milestone. VPC flow logs and ALB access logs stay in CloudWatch and S3. Prod's regional
bootstrap root gains the same module when the prod stage is stood up
([FIL-1147](https://linear.app/filecoin-foundation/issue/FIL-1147)).
