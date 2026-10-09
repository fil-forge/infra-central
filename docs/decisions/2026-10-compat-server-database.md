# The compatibility server's database is a second Aurora cluster, reached over a site-to-site VPN

The IST-1 compatibility server runs on an appliance outside AWS and keeps its database in prod
central ([FIL-1401](https://linear.app/filecoin-foundation/issue/FIL-1401),
[FIL-1436](https://linear.app/filecoin-foundation/issue/FIL-1436)). The database stays central
because other services will use it later from other hosts. It gets its own Aurora PostgreSQL
cluster in its own subnets, and the appliance reaches it through an AWS Site-to-Site VPN. The
cluster has no public endpoint.

## A cluster of its own

The appliance needs a network path to the cluster: a route to the appliance in the cluster's subnet
route table, and the appliance's address in the cluster's security group. Central's database
subnets route only inside the VPC
([2026-10-prod-first-stack.md](2026-10-prod-first-stack.md#database-subnets)), and a security group
applies to every database on a cluster. On central's cluster, that path would reach the endpoint
that also serves OpenBao's storage and every central service's database. Database credentials and
grants would be the only barrier left. A second cluster in its own subnets, with its own route
table and security group, carries the VPN route, and central's database network stays as it is.

Aurora snapshots and point-in-time recovery cover a whole cluster, so data dropped from a database
on central's cluster stays in central's 35-day recovery window and in its final and copied
snapshots. A separate cluster keeps its own recovery window. The cluster used for the test run holds
test data only and is deleted after it, with deletion protection off and the final snapshot skipped,
so nothing of it remains. While the test runs, its load stays off Sprue's writer.

## Engine and size

The compatibility server is planned as 32 shards on the appliance, each a set of processes with
their own small connection pools. Opened directly, those pools are estimated at 1,000–1,100
connections, and up to about 1,750 if every pool fills. PgBouncer on the appliance takes them
instead and holds an estimated 300 connections to the cluster. Aurora and RDS PostgreSQL derive the
default limit from the same formula, `LEAST(DBInstanceClassMemory/9531392, 5000)`, where
`DBInstanceClassMemory` is the instance's memory less what the OS and RDS reserve. That comes to
just under 1,800 on a 16 GiB instance and just under 900 on an 8 GiB one. A 16 GiB
`db.r8g.large` is also Aurora's smallest class that is not burstable, and it covers the server's
direct pools if PgBouncer is ever bypassed. At that size Aurora costs about $54 a month more than
RDS in us-east-2:

| Option | Default max_connections | Failover | Instances per month |
|---|---|---|---|
| RDS PostgreSQL `db.r8g.large`, Multi-AZ | just under 1,800 | 1–2 minutes | $349 |
| Aurora PostgreSQL `db.r8g.large`, writer and reader | just under 1,800 | under a minute, often under 30 seconds | $403 |

If the direct pools ever need to run without PgBouncer at full size, both instances move to
`db.r8g.xlarge` (32 GiB, just under 3,600 connections), $806 a month for the pair.

The `aurora` module sets 35 days of point-in-time recovery, deletion protection with a final
snapshot and `rds.force_ssl`, and encrypts with a key passed in. In prod that is the multi-region
key from the regional bootstrap, which the planned backup copies to another account and region need
([FIL-1298](https://linear.app/filecoin-foundation/issue/FIL-1298),
[FIL-1292](https://linear.app/filecoin-foundation/issue/FIL-1292)). The `database` module is shaped
for dev and staging and uses the account's default RDS key, whose snapshots another account can
receive only after each one is copied under a customer-managed key. Reusing the `aurora` module
takes one new input, a cluster name, since every name is `fc-${stage}` today.

The cluster runs Aurora PostgreSQL 16, matching central, on Aurora Standard storage. The test run
uses a writer alone, about $201 a month, so an instance failure takes the database down for up to
about 10 minutes while Aurora recreates it. The production cluster runs a writer and a reader in
different zones.

## Site-to-site VPN

| Part | Choice |
|---|---|
| AWS side | A virtual private gateway attached to the VPC. One VPN connection per appliance site, static routing, two tunnels ending in different availability zones. |
| Routing | The gateway propagates the site's route into the new database route table only. Central's database route table is unchanged. |
| Security group | 5432 from the appliance's private address and from the provision Lambda's security group. No other source can reach the database. |
| Appliance side | strongSwan on the host with both tunnels up, route-based, with one xfrm interface per tunnel. A health check moves the database route between tunnels, reverse-path filtering is loose because AWS answers on the tunnel it prefers, and TCP MSS is clamped. |
| Appliance addressing | Each site gets a private /32 from `10.21.0.0/24`, outside the VPC, on a dummy interface, and the server's database traffic is source-NATed to it. The VPN's static route and the security group name that address, and the appliance routes only `10.20.192.0/18` into the tunnel. |
| Encryption in transit | IPsec on the tunnel, and TLS to Postgres with `rds.force_ssl=1` and clients on `sslmode=verify-full`. |
| DNS | None needed. The cluster endpoint is a public DNS name that resolves to the cluster's private addresses. |
| Tunnel options | Pinned on both tunnels: IKEv2 only, AES256-GCM-16 with SHA2-384 in both phases, DH groups 20 and 21. strongSwan in Debian 12 and 13 and Ubuntu 24.04 supports all of them, and AWS's defaults would also accept AES-128, SHA-1 and DH group 2. |
| Keys | Pre-shared keys stored in Secrets Manager (`preshared_key_storage = "SecretsManager"`), out of Terraform state. |
| Monitoring | A Grafana alert rule on the connection's `TunnelState` (dimension `VpnId`) below 1, fed by adding `AWS/VPN` to the metric stream. It fires when either tunnel is down, including during AWS's tunnel maintenance. Nothing in the account routes CloudWatch alarms to on-call, and every other alert is a Grafana rule. |

The VPN costs about $44 a month per site: $36.50 for the connection and $7.30 for the two tunnel
addresses. The virtual private gateway is free. Data leaving AWS costs $0.09/GB, the same as on any
path that crosses the internet. A Transit Gateway would add $0.05 an hour per attachment and
$0.02/GB, which pays off only with many sites or VPCs.

A WireGuard router on a small EC2 instance in the VPC costs less, about $10 a month, and needs no
route in the database subnets, because the router source-NATs appliance traffic to its own VPC
address. It also adds an internet-facing instance to the VPC that has to be patched and kept
running, and it is a single point of failure. The managed VPN has neither.

### What each appliance needs from its provider

- One static public IPv4 address. The customer gateway is defined by that address, so a change
  means a new customer gateway. The VPN connection moves to it in place and keeps AWS's tunnel
  addresses and keys, after a brief outage. Onboarding already takes each node's egress address to
  bind its unseal token, and it may be the same one.
- UDP 500, UDP 4500 and IP protocol 50 (ESP) open in both directions between the appliance and the
  two AWS tunnel addresses, with no upstream filtering or rate limiting of IPsec. ESP can be dropped
  from the list if the appliance forces UDP encapsulation.
- The address either sits on the host or is translated in front of it. Both work, and translation
  changes the strongSwan identity configuration.
- The path MTU to the internet, expected to be 1,500 bytes. A smaller one, such as PPPoE's 1,492,
  lowers the tunnel MTU the appliance sets (1,446 bytes with AES-GCM, 1,438 with NAT traversal).

A second address and a second VPN connection would make the appliance side redundant. One is
enough while the server runs on one appliance.

## Placement in Terraform

The cluster's subnets take /20 indexes 12–14 of the VPC (`10.20.192.0/20` to `10.20.224.0/20`).
Indexes 9–11 cannot be covered by one route without including central's third database subnet.
Indexes 12–15 sit inside one free /18.

Sites are listed per stage in the shared constants module, as `compat_server_sites`, keyed by stage
and then by the appliance's region label, with each site's public and private address. Both roots
read the one list. Staging appliances run on different hosts from prod ones, so each stage has its
own sites, and a stage whose list is empty gets no gateway. A stage with sites must also have the
cluster.

A VPC cannot be deleted while a gateway is attached to it, so the pieces split across roots. The
customer gateway, the virtual private gateway and the VPN connection live in the regional bootstrap
root, which survives the post-test reset
([FIL-1396](https://linear.app/filecoin-foundation/issue/FIL-1396)) and keeps the tunnel addresses
and keys stable. That root is applied by hand, so adding a site is an operator step. The gateway
attachment, the route propagation and the cluster live in the platform root, so a reset that
destroys the platform root also deletes the cluster. Whether a VPN connection on a detached gateway
keeps its tunnel addresses when the gateway is attached again is tested once before the reset, as a
runbook step. If it does not, the connection can move to a new gateway, which AWS documents as
keeping its tunnel addresses and options.

Dropping the cluster outside a reset, as at the end of the test cycle, also empties the stage's
site list, because a stage with sites must have the cluster. The hand-applied bootstrap then
deletes the gateway and the VPN connections, and the next cycle's tunnels get new addresses and
keys.

## Work this leaves for the server and the appliance

- The server connects as more than one login role. The provision Lambda creates one login role per
  database today. It needs the second cluster's master secret and a way to create three roles:
  `pandora`, which owns the database and is used only by the loader; `pandora_storage_server` for
  the server's daemons; and a read-only `ergo_proxy`. The two login roles get a 15-second
  `statement_timeout`. Each role's DSN goes to SSM with `sslmode=verify-full`, and table grants
  live in the server's own grants file.
- Passwords minted in central's secret store have no path into an appliance's OpenBao yet.
- The server's Postgres client must support SCRAM authentication.
- Connections cross a WAN, so clients set TCP keepalives and `tcp_user_timeout`, and long-lived
  connections reconnect after a failover.
