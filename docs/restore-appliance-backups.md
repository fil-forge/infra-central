# Restoring an appliance's backups after its backup key leaks

A region's backup writer key cannot delete a backup or change a stored version. It can add versions
under `<region>/`, and that is enough to spoil a restore. A put at an existing key makes the forged
object the current version, which a plain `GetObject` reads, while the genuine one stays locked
behind it. A put at a new key adds a backup that never existed, such as a newer base backup that
WAL-G's `backup-fetch LATEST` would choose. WAL-G and an OpenBao snapshot restore both read current
versions, so after a leak neither may read `<region>/` directly.

S3 sets each version's `LastModified` itself, so no writer can backdate one. The procedure picks a
cutoff before the leak, copies the latest version of each key written before it to a prefix no
writer key can reach, and restores from that copy.

For an object uploaded in parts, `LastModified` is when the upload started, so an upload the node
started before the cutoff and finished after it counts as written before the cutoff. Its parts are
still the node's. Adding a part or finishing the upload takes its upload ID, and the writer key
cannot list in-progress uploads or their parts.

Every backup written at or after the cutoff is lost, genuine ones included. Postgres recovers to the
last WAL segment archived before the cutoff, and OpenBao to the last snapshot taken before it.

This covers a leaked key. A node you no longer trust also has to be retired, as
[Retiring a node you no longer trust](appliance-onboarding.md#retiring-a-node-you-no-longer-trust)
describes. Why the bucket accepts a put at an existing key is in
[decisions/2026-11-appliance-backup-target.md](decisions/2026-11-appliance-backup-target.md#locked-for-35-days-then-expired).

## Delete the key

Stop the leaked key first, so nothing new lands under the prefix while you work. Before deleting it,
note its ID and `CreateDate`, which the cutoff may need:

```bash
aws iam list-access-keys --user-name forge-nodes-backup-staging-eu-central-3
```

If the node keeps taking backups, reissue its key:

```bash
make mint-appliance-credentials STAGE=staging REGION=eu-central-3 NODE_IP=203.0.113.7 MINT_ARGS=--reissue-backup-key
```

The script deletes the old key in IAM before it mints the new one.
[Minting again](appliance-onboarding.md#minting-again) covers delivering the replacement. The node
writes under `<region>/` again once it stores the new key, and those writes do not affect the
restore.

If the node will not take backups again, delete the key without a replacement:

```bash
aws iam delete-access-key --user-name forge-nodes-backup-staging-eu-central-3 --access-key-id <key id>
```

## Choose the cutoff

The cutoff is the earliest moment the key could have left the node's control, which is usually well
before the moment the leak was noticed. If the node never managed to exchange its wrapping token,
the key was never the node's, and the cutoff is its `CreateDate`.

S3 keeps no record of which key wrote a version unless CloudTrail data events are on for the
bucket, and this repository turns none on. The bucket cannot tell you when the leak happened, so the
cutoff comes from what you know about the leak. An early cutoff loses more recent backups. A late
one can restore a forged object. When unsure, choose the earlier time.

A version written before the cutoff is deleted 36 days after it was written, like any backup. Copy
promptly: the copy carries a fresh 35-day lock.

## Copy the backups as of the cutoff

Run this with the `AdministratorAccess` SSO role for the stage's account. The cutoff is UTC, to the
second:

```bash
scripts/restore-appliance-backups.sh staging eu-central-3 2026-11-05T14:00:00Z
```

For every key under `eu-central-3/` it takes the latest version written before the cutoff and copies
it to `restores/eu-central-3/20261105T140000Z/` in the same bucket, keeping the rest of the key. A
key first written at or after the cutoff is left out. So is a key whose latest entry before the
cutoff is a lifecycle delete marker, because it had expired by then. What lands under the target is
the region's prefix as a listing at the cutoff would have shown it. The script refuses a cutoff in
the future, which would take every current version, forged ones included.

S3 lists times to the second, and lists delete markers apart from versions. When a key's latest
version and a delete marker share the last second before the cutoff, nothing says which came first,
so the script leaves the key out and warns, naming it in `ambiguous.txt`. Copy such a key by hand
if the restore needs it.

It reads everything first, prints how many keys it will copy and leave out, and copies after you
type `copy`. It also lists the keys that have a version written at or after the cutoff in front of
the one it copies. A leaked key leaves these, and so does WAL-G when it retries an upload, so an
entry is a place to look rather than proof of forgery.

The script reads the region's prefix and writes only under `restores/`. No writer key can write
there, because each writes only under its own `<region>/`. The bucket's lock and lifecycle apply to
the copies as to any backup, so they are locked for 35 days and gone after 36.

It keeps its records in a local directory it names at the start. `plan.json` holds the version ID
and ETag of every object copied; keep it with the incident notes. A failed copy leaves its key out
of the target, and the script ends by naming the missing keys. Run it again with the same cutoff: it
skips every key already under the target. It refuses an object larger than 5 GiB, the most one
`CopyObject` request can copy, and names it.

## Restore from the copy

Restore as you would from `<region>/`, with the prefixes the script prints at the end:

- Postgres: `WALG_S3_PREFIX=s3://<bucket>/restores/<region>/<cutoff>/postgres`, with
  `S3_ENABLE_VERSIONING=disabled` as on the node. Credentials that can read the bucket's versioning
  state would otherwise switch WAL-G to listing object versions.
- OpenBao: the latest snapshot under `s3://<bucket>/restores/<region>/<cutoff>/openbao/`.

The node's writer key cannot read the copy, by design. The restore reads with credentials that can,
which today means the `AdministratorAccess` or `ReadOnlyAccess` role, as
[Who can read the backups](decisions/2026-11-appliance-backup-target.md#who-can-read-the-backups)
records. The node-side restore steps for each service arrive with
[FIL-1599](https://linear.app/filecoin-foundation/issue/FIL-1599) and
[FIL-1745](https://linear.app/filecoin-foundation/issue/FIL-1745).
