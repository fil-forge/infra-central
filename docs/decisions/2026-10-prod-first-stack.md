# The first prod stack is disposable

Prod first runs as a disposable stack in the filone-production account (`811430801166`), region
`us-east-2`. It carries a 100–200 TB test run of synthetic data at the launch rate of 3 GB/s. After
the test run, its platform and apps roots are destroyed and re-applied with the Round 1 hardening,
following [FIL-1396](https://linear.app/filecoin-foundation/issue/FIL-1396). The bootstrap roots,
the per-service Route53 zones and the payer and transactor keys survive.

## Topology and sizes

Prod uses its committed topology: three availability zones, a NAT gateway per zone, a Multi-AZ RDS
instance, Global Accelerator and Container Insights.

The database is a `db.m7g.large` with 50 GiB of gp3, autoscaling to 100 GiB, with backups kept for
30 days. At the launch rate, central sees 12–22 object PUTs per second. Each PUT costs Sprue about
15 new rows in 7 commits, so the database takes about 150 commits/s for the whole run. A burstable
class would run out of CPU credits during an 18-hour run at that rate. A 200 TB run adds about
7.5 GB of live rows.

Sprue runs at 1 vCPU and 2 GiB with a 20-connection pool. It is the only service on the per-PUT
path. Every other service, OpenBao included, keeps its default size and runs one task.

The test run's Sprue CPU, database CPU, commit latency and lock waits set the starting size of the
Aurora cluster that replaces this instance at the reset.

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

Prod starts on Filecoin mainnet with the FWSS deployment recorded in
[fil-forge/filecoin-services](https://github.com/fil-forge/filecoin-services/blob/main/service_contracts/deployments.json)
and USDFC. It moves to the contracts from
[FIL-1277](https://linear.app/filecoin-foundation/issue/FIL-1277) once they are deployed.

## Database subnets

The first stack uses the shared private subnets. Moving a live instance to a new subnet group
replaces it, which the reset does anyway.
[FIL-1295](https://linear.app/filecoin-foundation/issue/FIL-1295) creates the database for the
hardened stack and decides whether it gets dedicated subnets with no route out.
