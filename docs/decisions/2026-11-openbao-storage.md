# OpenBao's storage moves to a database instance of its own

Each stage gets a second database instance, and prod a second Aurora cluster, that holds OpenBao's
storage and nothing else. Restoring the services' data then leaves every unseal token, transit key
and AppRole as it was. The proposed order is dev first, then staging, then prod no later than its
post-test reset ([FIL-1396](https://linear.app/filecoin-foundation/issue/FIL-1396)). The move is
proven when the [restore runbook](../restore-database.md), run on dev against the services'
instance, finds every region's key and token unchanged.

## A restore of the shared instance rolls back the root of trust

OpenBao keeps its storage in the `openbao` database on the instance that also holds sprue, hilt,
swarf and plc. Point-in-time recovery restores a whole instance. A restore drill on dev on
2026-11-11 ([FIL-1149](https://linear.app/filecoin-foundation/issue/FIL-1149)) restored that
instance to a time T and recorded what happened to OpenBao's state:

| State before the restore | Observed after the restore |
|---|---|
| An unseal token revoked 14 minutes after T | Live, with no record naming it |
| An unseal token minted after T | Gone, while SSM still recorded it |
| A transit key created after T | Gone; the next vault phase would have created a new key under the same name |
| A token live at T whose period ran out before the restore | Expired |
| The appliance's token, minted before T and renewed since | Live; the node unsealed after a restart |
| hilt's AppRole `secret_id`, issued after T | Unknown to OpenBao until the vault phase replaced it |

A revoked credential working again, and a node that can never unseal again, are the two results
that matter. Each token issued after T also needs a re-mint that involves the node's operator.
Today every restore brings these with it, including one taken to recover a single service's data.

## Options

| | OpenBao on its own instance | Separate database on the shared instance | Shared, with single-database restores | Raft storage |
|---|---|---|---|---|
| Restoring the services' data | Leaves OpenBao as it is | Rolls OpenBao back | Leaves OpenBao as it is, when the operator picks this procedure | Leaves OpenBao as it is |
| Added cost per month (estimate) | dev about $14, staging about $26, prod $201–403 | none | none | an EFS volume or an EC2 host |
| Work to adopt | Seed writes OpenBao's DSN for a second host; one copy per stage | none, this is the current layout | A runner inside the VPC, which central does not have | A new storage backend and backup path, and durable disk for a Fargate task |
| Network boundary for OpenBao's storage | Its own security group | Shared with every service | Shared with every service | Its own volume |
| Reversible | Yes, by copying the database back | n/a | Yes | Only with a migration back to Postgres |

OpenBao on its own instance gives it a recovery window of its own and a security group that only
OpenBao and the provision Lambda can reach. Today every task shares one service security group, so
per-database credentials are the only boundary between OpenBao's storage and the other services.

Keeping one instance means hilt's rows and the tenant secrets in OpenBao always come back from the
same moment, and adds no cost or migration.

Single-database restores keep that layout and still spare OpenBao: restore the instance aside, then
`pg_dump` and `pg_restore` only the damaged databases into the live one. It needs a runner inside
the VPC with access to both, and copying sprue's data that way is slower than swapping instances.

Raft storage separates OpenBao from Postgres entirely, matches how the appliances run it, and gives
OpenBao its own high availability. OpenBao stores in Postgres today because Fargate has no durable
disk and Postgres avoided an EFS filesystem, so raft is the largest change of the four.

## Engine, size and cost

| Stage | Instance | Recovery window | Cost per month |
|---|---|---|---|
| dev | RDS PostgreSQL 16, `db.t4g.micro`, 20 GiB gp3 | 1 day | about $14 (estimate) |
| staging | RDS PostgreSQL 16, `db.t4g.small`, 20 GiB gp3 | 7 days | about $26 (estimate) |
| prod | Aurora PostgreSQL 16, `db.r8g.large` | 35 days | $201 writer alone, $403 with a reader |

The dev and staging estimates are us-east-2 on-demand list prices for the instance and its storage.
The prod figures are those of the
[compatibility server's cluster](2026-10-compat-server-database.md#engine-and-size). With a writer
alone, a failed instance leaves OpenBao down for up to about 10 minutes while Aurora replaces it,
and no appliance whose OpenBao restarts in that time can unseal. Whether prod runs a reader is
decided with the availability target
([FIL-1157](https://linear.app/filecoin-foundation/issue/FIL-1157)). The `aurora` module already
takes a cluster name; the `database` module needs the same input. Prod's cluster uses the
multi-region key from the regional bootstrap, as the services' cluster does.

## hilt's rows and its tenant secrets restore in order

hilt keeps tenants and access keys in its database and their secrets in OpenBao's KV store. Once
the two live on separate instances they can be restored to different times. A secret without its
row does no harm. A row without its secret is a tenant that cannot work. When both are restored,
OpenBao's restore time is never earlier than hilt's.

## Moving each stage

Transit keys cannot be exported, so each stage moves the `openbao` database as a whole. With
OpenBao stopped, copy the database with `pg_dump` and `pg_restore` into the new instance, point
`/forge-central/<stage>/openbao/postgres-dsn` at it, and start OpenBao. Every token, key and AppRole
comes across unchanged. The seed phase writes that DSN from one host today and needs a second, as it
already has for the pandora cluster. Disaster recovery for both instances is planned in
[FIL-1297](https://linear.app/filecoin-foundation/issue/FIL-1297).

Until a stage has moved, the [restore runbook](../restore-database.md) restores its shared
instance and checks every region's key before any vault phase runs.
