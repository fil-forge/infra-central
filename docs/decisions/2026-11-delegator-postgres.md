# The delegator keeps its state in its own database on central's cluster

The delegator holds two sets of records: the allow list of Piri DIDs permitted to register, and the
registration of each Piri that did. Until now they sat in two DynamoDB tables per stage,
`fc-<stage>-delegator-allow-list` and `fc-<stage>-delegator-provider-info`, outside the Aurora
backups, the DR replica and the reset-apps phase. They move to a `delegator` database on central's
Aurora cluster, set up the way sprue, hilt, swarf and plc are
([sc-1123](https://app.shortcut.com/filone/story/1123)).

## One more database consumer

The seed phase gives the delegator a role and a database named `delegator`, and stores its DSN as a
SecureString at `/forge-central/<stage>/delegator/postgres-dsn`. ECS passes it to the task as
`REGISTRAR_STORE_POSTGRES_DSN`, and `REGISTRAR_STORE_TYPE=postgres` selects the backend
([fil-forge/delegator#96](https://github.com/fil-forge/delegator/pull/96)). The delegator creates
its tables with goose migrations when it starts, under an advisory lock, as the other services do.
Its pool takes up to 10 connections. The reset-apps phase drops and recreates the database with the
others, so a reset wipes the delegator's records in the same step.

## The onboard phase writes the allow list into the delegator's table

The onboard phase puts each appliance's Piri DID on the allow list. It writes the row itself,
connected with the delegator's own DSN, into the `allow_list` table the delegator's migrations
create. The delegator offers no API for the write, and its `registrar store allow-did` command needs
a shell in its task, which none of its tasks has. The provision Lambda runs in the VPC and can read
the DSN, so writing the row directly is the shortest path. Connecting as the table's owner rather
than as the master user means the write needs no grant beyond what the delegator already holds.

The table exists only once the delegator has started on Postgres and migrated. Onboarding already
needs the stage's services up, because it registers the appliance with sprue and hilt over their
public APIs, so in practice the table is there. When it is not, the phase stops before its first
write and says that the delegator has not migrated its database yet. It never reports the DID as
absent from a table that does not exist.

The write ties infra-central to the delegator's schema: the `did`, `added_by` and `notes` columns of
`allow_list`, and `added_at`, which the delegator fills in itself. A change to that table in the
delegator has to keep them, or land together with a change here.

## Each stage switches on its own

`delegator_store` in each stage's platform root names the backend, `dynamodb` or `postgres`. The
platform passes it to the provision Lambda, which picks the allow list the onboard phase writes, and
exports it to the apps root, which sets the delegator's environment and its task role's grants from
it. One value per stage keeps the two from disagreeing.

Every merge to `main` applies all three stages, so a module-wide switch would move prod in the same
apply as dev. The stages switch in order, dev, staging, prod. The change that switches a stage also
bumps its `seed_trigger`, and needs two images pinned for that stage:

- a delegator image with the Postgres backend, without which the delegator finds no DynamoDB
  settings and does not start
- a provision image with the switch, which seeds the database and writes the allow list where
  `delegator_store` says; an older image writes it to DynamoDB without complaint

Each stage applies its platform root before its apps root. The seed run creates the database and its
DSN in the platform apply, and the delegator's new task starts on it in the apps apply that follows.

## The provision Lambda copies the existing records

A stage switched to Postgres keeps every allow-list row and provider registration it had. The
provision Lambda's `copy-delegator-records` phase scans both DynamoDB tables and inserts their items
into the delegator's tables, connected as the delegator's role. Without the copy, each region would
have to be onboarded again, and each Piri would stay unregistered until its next `piri init`
registered it again.

The copy runs after the switch, because the delegator's migrations create the tables when its task
first starts on Postgres. Until it runs, the allow list is empty, which matters only to a `piri init`
in that window: the delegator refuses it, and the node keeps serving from its existing
configuration. Running it is an operator step right after the switch's deploy:

```bash
aws lambda invoke --function-name fc-<stage>-provision --cli-binary-format raw-in-base64-out \
  --payload '{"phase":"copy-delegator-records"}' /dev/stdout
aws lambda invoke --function-name fc-<stage>-provision --cli-binary-format raw-in-base64-out \
  --payload '{"phase":"copy-delegator-records","confirm":true}' /dev/stdout
```

The first call is a dry run that lists, per table, the keys Postgres lacks and the keys it already
holds. The second inserts the missing rows in one transaction. A row already in Postgres was written
after the switch, so it is kept, which also makes the phase safe to run again. Every column keeps its
DynamoDB value, timestamps included. An item missing an attribute the delegator always wrote, or
holding one of the wrong type, fails the phase and names the item.

The Lambda's grant on the tables is `dynamodb:Scan` alone, so the copy cannot change them. They stay
as they are until every stage has switched.

## The tables go in two applies

The DynamoDB tables stay, untouched, until every stage runs on Postgres. They are the fallback if
the switch has to be undone. Staging's and prod's tables
have deletion protection, so removing them takes two merges: the first takes out every reader,
writer and grant and turns deletion protection off, the second deletes the tables. DynamoDB keeps a
system backup of a table deleted with point-in-time recovery on, named
`<table>$DeletedTableBackup`, for 35 days. Dev's tables have point-in-time recovery off and leave
none.
