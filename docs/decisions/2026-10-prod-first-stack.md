# The first prod stack carries a test run before launch

Prod first runs in the filone-production account (`811430801166`), region `us-east-2`. It carries a
100–200 TB test run of synthetic data at the launch rate of 3 GB/s. After the test run, the stack is
reset with the Round 1 hardening, following
[FIL-1396](https://linear.app/filecoin-foundation/issue/FIL-1396), in one of two ways: its platform
and apps roots are destroyed and re-applied, or its data is wiped and the hardening is applied in
place, keeping the Aurora cluster, its subnets and the VPC. Either way, the bootstrap roots, the
per-service Route53 zones, the KMS keys of the Aurora cluster and of OpenBao's seal, and the payer
and transactor keys survive. The appliances enrolled for the test run are wiped and re-onboarded
after the reset.

## Topology and sizes

Prod uses its committed topology: three availability zones, a NAT gateway per zone, an Aurora
PostgreSQL cluster with a writer and a reader in different zones, Global Accelerator and Container
Insights.

At the launch rate, central sees 12–22 object PUTs per second. Each PUT costs Sprue about 15 new
rows in 7 commits, so the database takes about 150 commits/s for the whole run. A burstable class
would run out of CPU credits during an 18-hour run at that rate. A 200 TB run adds about 7.5 GB of
live rows.

Both cluster instances are `db.r8g.large`, 2 vCPU and 16 GiB. The reader has the writer's class
because it takes the writer's load after a failover. The cluster runs Aurora PostgreSQL 16 on
Aurora Standard storage and keeps 35 days of point-in-time recovery. Its key is a multi-region KMS
key from the regional bootstrap, so backups can be copied to another region and another account
([FIL-1298](https://linear.app/filecoin-foundation/issue/FIL-1298),
[FIL-1292](https://linear.app/filecoin-foundation/issue/FIL-1292)). The r-class and the engine
version both support Global Database, so the DR secondary
([FIL-1297](https://linear.app/filecoin-foundation/issue/FIL-1297)) needs no instance change. The
two instances cost about $404 a month before I/O, against about $258 for a Multi-AZ RDS
`db.m7g.large`; the reader and Aurora's storage make the difference.

OpenBao seals its storage with a multi-region KMS key from the regional bootstrap, like the
cluster's. A key's multi-region flag is fixed when the key is created, so OpenBao never has to move
to a new seal key, and a platform root applied in the DR region unseals with the key's replica
there ([FIL-1303](https://linear.app/filecoin-foundation/issue/FIL-1303),
[FIL-1445](https://linear.app/filecoin-foundation/issue/FIL-1445)).

Sprue runs at 1 vCPU and 2 GiB with a 20-connection pool. It is the only service on the per-PUT
path. Every other service, OpenBao included, keeps its default size and runs one task.

The test run's Sprue CPU, database CPU, commit latency, lock waits and I/O rate confirm or correct
the instance class and the storage type before launch.

## Deploys

Every merge to `main` applies prod, as staging does. An approval step follows in
[FIL-1394](https://linear.app/filecoin-foundation/issue/FIL-1394), before the hardened stack carries
production data.

## DNS

`fil-forge.com` is served by Cloudflare, and the services use names directly beneath it. Each
service name has its own Route53 zone in the prod account, created by the prod account bootstrap
and delegated by an NS record in fil-one/infrastructure. A wildcard certificate for
`*.fil-forge.com` would validate through a record in the Cloudflare zone, so the prod certificate
lists each hostname and validates it in that hostname's own zone.

## Contracts

The test run uses the Calibration testnet (chain 314159) and the same FWSS, FilecoinPay, service
provider registry and USDFC addresses as dev and staging, from
`terraform/envs/staging/platform/terraform.tfvars`. Prod moves to Filecoin mainnet with the contracts from
[FIL-1277](https://linear.app/filecoin-foundation/issue/FIL-1277) once they are deployed.

## Database subnets

The cluster has its own subnets, one per zone, whose route table holds only the local route. The
database security group already allows no outbound connections, so the subnets are a second layer
in case that rule ever changes. They cost nothing. A live cluster cannot move to another subnet
group, so the choice is made before the first apply, and it holds if the cluster carries over into
launch.
