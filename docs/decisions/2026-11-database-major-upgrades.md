# Central's databases take major PostgreSQL upgrades in place

Each stage's own database moves to a new PostgreSQL major version through an in-place upgrade that
Terraform applies: the RDS instances in dev and staging, and the Aurora cluster in prod. A stage
allows the upgrade with `db_allow_major_version_upgrade` in its platform root, which also has the
provision Lambda run `ANALYZE` in every central database once the new version is up.
`db_apply_immediately`, set beside it, makes the upgrade start when the apply runs. Staging and
prod turn both on only in the pull request that upgrades them; dev keeps them on.

The first such upgrade moves all three stages from PostgreSQL 16 to 18, prod from Aurora 16.15 to
18.6 ([sc-1085](https://app.shortcut.com/filone/story/1085)).

## Why in place

The database holds OpenBao's storage and every service's database, and losing it costs every
regional appliance its ability to unseal. Dropping the cluster and creating it on the new version,
the way [#407](https://github.com/fil-forge/infra-central/pull/407) and
[#408](https://github.com/fil-forge/infra-central/pull/408) moved the pandora cluster, works only
for a cluster that holds nothing worth keeping.

RDS Blue/Green Deployments would cut the outage to a switchover of about a minute, and they are
unavailable here. AWS does not support them on a database whose master password Secrets Manager
manages, and every central database sets `manage_master_user_password`, because the provision
Lambda reads the password from that secret. Blue/Green would also need logical replication turned
on, which takes a reboot, and it stalls on any DDL or `GRANT` run before the switchover.
`aws_rds_cluster` has no Blue/Green support in the AWS provider.

## What the two inputs do

Both inputs are off by default, and each stage's platform root sets them.

- **`db_allow_major_version_upgrade`** passes `allow_major_version_upgrade` to the RDS instance or
  the Aurora cluster. Without it, AWS refuses a version change that crosses a major version.
- **The same input, with `db_apply_immediately` also on,** makes the platform module create an
  `analyze` invocation of the provision Lambda. Its input carries the engine version, so it runs
  after every version change, once the database module has finished.
- **`db_apply_immediately`** passes `apply_immediately`. Without it, AWS holds a version change
  until the next maintenance window, and the outage starts at a time nobody chose.

They are separate so a stage can apply other changes at once without allowing a major upgrade, or
leave an upgrade to its maintenance window. In the second case the apply finishes before the
upgrade has happened, so the platform module creates no `analyze` invocation and prints a warning
with the command that runs the phase by hand once the window has passed.

Two changes to the `aurora` module apply whatever the inputs say. Its cluster parameter group is
created before the old one is destroyed: the group's name carries the major version, and the
cluster has to move to the new group before the old one can go. Its instances leave
`engine_version` unset, because an instance runs its cluster's version and the cluster upgrades
it.

The pandora cluster upgrades the same way, through `allow_major_version_upgrade` and
`apply_immediately` in the `pandora_db` object. Its own `analyze` invocation runs the phase with
`"target": "pandora"`, which analyzes the `pandora` database on that cluster, and its own check
warns when the upgrade is left to the maintenance window. `docs/pandora-vpn.md` has the steps.

## The outage

During the upgrade, the writer stops serving while it runs `pg_upgrade`. OpenBao and every service
lose their database for that time, and each reader takes a brief outage of its own afterwards. AWS
publishes no figure for how long the writer is down. An appliance whose own OpenBao restarts in
that window cannot unseal until central's OpenBao is back.

Before starting, AWS snapshots the cluster as `preupgrade-…`, and it rolls back an upgrade that
fails. Once an upgrade has succeeded, returning to the old version means restoring that snapshot
into a new cluster, which loses every write made after it.

## Order and rehearsal

The stages upgrade one at a time, one pull request each, and each merges after the previous stage's
apply has finished and its services are healthy. Dev and staging run the services and OpenBao
against the new version and exercise the `analyze` phase. They run RDS, so they do not exercise
Aurora's upgrade.

Prod is rehearsed first on a copy of its cluster, which shows how long the writer is down and
surfaces any failing pre-upgrade check. The copy shares the cluster's storage until it diverges, so
it is quick to make. The cluster's security group lets nothing else in, and nothing connects to the
copy.

```bash
aws rds restore-db-cluster-to-point-in-time --region us-east-2 \
  --source-db-cluster-identifier fc-prod --db-cluster-identifier fc-prod-upgrade-rehearsal \
  --restore-type copy-on-write --use-latest-restorable-time \
  --db-subnet-group-name fc-prod --vpc-security-group-ids <the cluster's security group>
```

```bash
aws rds create-db-instance --region us-east-2 --engine aurora-postgresql \
  --db-cluster-identifier fc-prod-upgrade-rehearsal \
  --db-instance-identifier fc-prod-upgrade-rehearsal-1 --db-instance-class db.r8g.large
```

Terraform moves the cluster to a new parameter group of its own in the same call, so the rehearsal
does too:

```bash
aws rds create-db-cluster-parameter-group --region us-east-2 \
  --db-cluster-parameter-group-name fc-prod-upgrade-rehearsal-aurora-postgresql18 \
  --db-parameter-group-family aurora-postgresql18 --description "Upgrade rehearsal"
```

```bash
aws rds modify-db-cluster-parameter-group --region us-east-2 \
  --db-cluster-parameter-group-name fc-prod-upgrade-rehearsal-aurora-postgresql18 \
  --parameters ParameterName=rds.force_ssl,ParameterValue=1,ApplyMethod=pending-reboot
```

Once the instance is available, upgrade the copy and read the start and end of the upgrade from the
cluster's events:

```bash
aws rds modify-db-cluster --region us-east-2 --db-cluster-identifier fc-prod-upgrade-rehearsal \
  --engine-version 18.6 --allow-major-version-upgrade \
  --db-cluster-parameter-group-name fc-prod-upgrade-rehearsal-aurora-postgresql18 --apply-immediately
```

```bash
aws rds describe-events --region us-east-2 --source-type db-cluster \
  --source-identifier fc-prod-upgrade-rehearsal --duration 360
```

Afterwards, delete the instance, then the copy with `--skip-final-snapshot`, then the parameter
group.

## Statistics after the upgrade

A major upgrade does not carry the planner's statistics across. Until a table is analyzed again,
the planner guesses its size and how its values are spread, and it can pick sequential scans or
poor join orders. Autovacuum analyzes a table once enough of its rows change, so busy tables recover
within minutes. A table that is read often and written rarely can go without statistics
indefinitely. HCP Terraform runs outside the VPC and cannot reach the database, so the provision
Lambda's `analyze` phase runs `ANALYZE` from inside it.

The phase connects to each central database as the master user, takes the database owner's role,
and analyzes every table outside the system schemas. The master user is not a superuser, and
`ANALYZE` skips a table its user may not analyze with a warning rather than an error, so any
warning fails the phase and the apply. A provision image built before the phase existed fails the
apply the same way, after the upgrade itself succeeded. Publish a newer image, pin it, and apply
again.

## The inputs after the upgrade

Staging and prod turn both inputs off again in one pull request once prod's upgrade has applied. A
later change of `db_engine_version` there then cannot cross a major version, and a database change
waits for the maintenance window again. Staging's instance holds the root of trust of a live
appliance, so it gets the same guard as prod.

Dev keeps both on. Its data can be reset, and its next major upgrade needs only the version change.
While `db_apply_immediately` is on, every change to dev's database instance applies at once rather
than in the maintenance window.

## PostgreSQL 18 compatibility

`aws rds describe-db-engine-versions` lists 18.6 as a direct major upgrade target from Aurora
16.15 in the prod account (checked on 2026-11-20), so the cluster skips 17. For the RDS instances,
the same command with `--engine postgres` and the instance's running version lists the targets.

OpenBao 2.6's documentation for its `postgresql` storage backend states a minimum of PostgreSQL 9.5
and no maximum, and its issue tracker has no report against PostgreSQL 18. Dev's apply is the first
time OpenBao runs on 18.

The upgrade crosses the incompatibilities listed for both 17 and 18. The ones a service could meet
are the safe `search_path` that maintenance commands such as `ANALYZE` and `CREATE INDEX` now use
in 17, `AFTER` triggers running as the role that queued them in 18, and warnings for MD5 passwords
in 18. Dev and staging run the services against 18 before prod does.

## Global Database

The DR secondary in [FIL-1297](https://linear.app/filecoin-foundation/issue/FIL-1297) turns prod's
cluster into a Global Database. A global cluster upgrades all its member clusters together, through
the global cluster rather than the regional one, so this procedure needs revisiting once that
secondary exists.

## Sources

- Aurora PostgreSQL major upgrades:
  <https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/USER_UpgradeDBInstance.PostgreSQL.MajorVersion.html>
- Aurora PostgreSQL upgrade targets:
  <https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/USER_UpgradeDBInstance.PostgreSQL.UpgradeVersion.html>
- Blue/Green limitations:
  <https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/blue-green-deployments-considerations.html>
- OpenBao's PostgreSQL storage backend:
  <https://openbao.org/docs/2.6.x/configuration/storage/postgresql/>
- PostgreSQL 17 and 18 release notes: <https://www.postgresql.org/docs/17/release-17.html>,
  <https://www.postgresql.org/docs/18/release-18.html>
