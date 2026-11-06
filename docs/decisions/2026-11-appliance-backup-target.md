# Appliance backups go to a compliance-locked bucket in central

Regional appliances push their Postgres WAL and base backups
([FIL-1599](https://linear.app/filecoin-foundation/issue/FIL-1599)) and their OpenBao raft snapshots
([FIL-1745](https://linear.app/filecoin-foundation/issue/FIL-1745)) off the host. [RFC 37]'s
"Backup & restore" section sets three requirements for where they go: central administers it, no
appliance credential can read, delete or overwrite a backup within 35 days, and no appliance can
reach another appliance's backups.

Each stage that takes backups gets one S3 bucket with Object Lock in compliance mode and a 35-day
default retention. Each region gets an IAM user that can add objects under its own prefix and
nothing more, with an access key the provision Lambda mints and delivers wrapped, the way it
delivers the unseal token. Staging and prod take backups. Dev takes none.

## One bucket per stage

The bucket is `forge-nodes-backups-<stage>-<account_id>`, and each region writes under its own
label:

| Prefix | Written by | Ticket |
| --- | --- | --- |
| `<region>/postgres/` | WAL-G, with `WALG_S3_PREFIX=s3://<bucket>/<region>/postgres` | FIL-1599 |
| `<region>/openbao/` | the raft snapshot upload | FIL-1745 |

A bucket per region would separate the appliances by resource instead of by policy, which is easier
to audit. It fails at retirement. S3 refuses to delete a bucket that holds a locked object, and
compliance mode means nobody can remove the lock, so a retired region's bucket would stand for 35
days after its last write, with Terraform failing to destroy it on every apply in between. A
stage-wide bucket outlives every region, and a retired region's prefix expires on its own.

S3 bucket names allow 63 characters. Staging's is 40 (`forge-nodes-backups-staging-654654381893`)
and prod's is 37. IAM user names allow 64, and `forge-nodes-backup-staging-` takes 27 of them,
leaving 37 for a region label; `eu-central-3` is 12. Preconditions on both resources fail the plan
before either limit is reached. A bucket has no capacity limit. A single object can be at most 5 TB,
and WAL-G splits a base backup into tar partitions well below that.

## Each region writes with a static access key

The README records "no static access keys anywhere" as an architecture decision. The appliance
backup writer is the exception. An appliance runs outside AWS, staging's `eu-central-3` on bare
metal, so it has no task role to inherit credentials from, and it needs a credential central issues
and can revoke.

Two alternatives were considered.

**OpenBao's AWS secrets engine** would issue short-lived STS credentials, with central OpenBao as
the only place a long-lived secret lives. OpenBao 2.6.0 does not ship that engine, so it would be an
external plugin to build, register and keep current. Central OpenBao runs as a Fargate task, and STS
credentials obtained by assuming a role from a task role are capped at one hour by role chaining.
Every appliance would then come back to central at least hourly, and its backups would stop
whenever central OpenBao did.

**IAM Roles Anywhere** issues short-lived credentials against an X.509 certificate, so no
long-lived AWS secret exists at all. It needs a certificate authority whose private key central
would have to protect, and an issuance and renewal path on every node. That is more machinery than
one writer per region justifies today.

So each entry in `appliance_regions` gets an IAM user, `forge-nodes-backup-<stage>-<region>`,
created by Terraform. Terraform does not create its access key, because the secret would land in
state. The provision Lambda's `appliance-backup-key` phase mints the key and wraps it through
central OpenBao's `sys/wrapping/wrap` with a 24-hour TTL. The operator delivers the wrapping token
the way they deliver the unseal token's, and the node exchanges it once. A failed exchange is a
compromise, for the same reason [the unseal token's is](2026-08-region-onboarding.md#the-unseal-token-is-delivered-wrapped).

The node stores the key in its local OpenBao, so a disk taken from the appliance holds it only
under the region's transit seal. Revocation is immediate. Deleting the key in IAM stops the node's
writes within seconds, even on a running appliance, where the unseal token only takes effect at the
next unseal. Retiring a region removes its label from `appliance_regions`, and the next apply
deletes the user, its policy and its key.

The key carries no `aws:SourceIp` condition, so a leaked key can write under its region's prefix
from anywhere until it is deleted. It still cannot read, delete or overwrite a backup. Binding it to
the node's egress CIDR, as the unseal token is bound, is a follow-up.

## One mint for both credentials

`scripts/mint-appliance-credentials.sh`, run as `make mint-appliance-credentials`, mints every
credential central issues an appliance: the unseal token through the `appliance-token` phase and the
backup key through the `appliance-backup-key` phase. It mints whichever of them the region lacks,
skips the ones it holds, and prints a wrapping token for each one it minted. A second run mints
nothing. The `appliance-token` phase skips a region whose unseal token is live, so a node still
never holds two live unseal tokens, and mints again for a region whose token has lapsed. A
credential added later gets its own phase in the same script.

Each credential has its own reissue flag, `--reissue-unseal-token` and `--reissue-backup-key`, so a
leaked backup key never forces an unseal-token rotation.

Reissuing the unseal token on every run was considered, so that one run always hands over both
credentials. Every such run would revoke the token the node is renewing, and the node's
`provision-platform.sh` skips claiming a seal token when it already has one, so the node would fail
to unseal at its next restart until someone followed the expired-token runbook.

Like `appliance-token`, the backup phase returns a credential and is never wired to an
`aws_lambda_invocation`.

## What a writer can do

| Action | On | Why |
| --- | --- | --- |
| `s3:PutObject`, `s3:AbortMultipartUpload` | `<region>/*` | Every backup upload, multipart included |
| `s3:GetObject` | `<region>/postgres/*.history*` | WAL-G's overwrite check |
| `s3:ListBucket` | the bucket, with `s3:prefix` like `<region>/*` | So that check sees 404 for a missing file |

The read is the one exception to "no appliance can read a backup". Before WAL-G uploads a timeline
history file, it reads the one already at that key and refuses to overwrite it if the content
differs. Without the read, every timeline switch fails its upload. A history file records the
timeline IDs and the WAL positions where they branched, and no table data. For a key that does not
exist S3 answers 404 only to a caller holding `s3:ListBucket`, and 403 otherwise, which WAL-G treats
as an error. The `s3:prefix` condition limits listing to the region's own prefix, so no appliance
can list the key names of another region's backups, which would reveal what backups exist and when.
`scripts/check-appliance-backup-access.sh` checks that the conditioned grant is enough for a 404.

A writer has no `s3:DeleteObject`, so it cannot place a delete marker in front of a backup either.

## Locked for 35 days, then expired

Object Lock runs in compliance mode with a 35-day default retention, so no credential in the
account, an administrator's included, can delete or overwrite a backup version before then. The
bucket has four lifecycle rules:

- The current version of every object expires after 35 days, which puts a delete marker in front of
  it.
- Noncurrent versions are deleted one day after they become noncurrent or when their lock lapses,
  whichever comes later, because lifecycle cannot delete a locked version. With a 35-day lock that
  is almost always the lock, so a backup is gone about 36 days after it was written.
- Expired delete markers are removed, in a rule of their own because S3 refuses that action beside
  `days`.
- Incomplete multipart uploads are aborted after seven days.

The bucket does not enforce `If-None-Match` on puts, because WAL-G never sends the header. A put to
an existing key adds a version. The earlier version stays locked until its own retention ends, 35
days after it was written, and is deleted after that like any other backup. WAL-G re-archives a WAL
segment when an upload is retried, so some keys collect several versions.

Every request without TLS is denied by the bucket policy, and public access is blocked.

## Encryption at rest is SSE-S3

A customer-managed KMS key would gate reads by `kms:Decrypt`. A multipart upload under SSE-KMS
needs `kms:Decrypt` on the uploader as well, so every appliance would hold the permission the key
was meant to withhold. SSE-S3 encrypts at rest with no key to grant.
[FIL-1619](https://linear.app/filecoin-foundation/issue/FIL-1619) adds encryption to a public key
on the node before upload, which keeps backup content unreadable to anyone who can read the bucket.

## Who can read the backups

There is no dedicated restore role yet. Engineers restore with the `AdministratorAccess` SSO role,
and `ReadOnlyAccess`, which carries `s3:GetObject` on every bucket, can read the backups too. A
restore role, and keeping `ReadOnlyAccess` out of this bucket, are deferred.

CI cannot read them. The apply role's grant on `forge-nodes-backups-*` names bucket-level actions
only. The ARN pattern also matches the bucket's objects, so it is the action list that keeps CI out,
and the grant's comment says so for whoever edits it next. The plan role holds no `s3:GetObject`
outside the state bucket.

## The node's half

Central wraps five fields: `access_key_id`, `secret_access_key`, `bucket`, `prefix` and
`aws_region`. The node keeps the bucket, prefix and AWS region in its `node.env` as
`BACKUP_S3_BUCKET`, `BACKUP_S3_PREFIX` and `BACKUP_S3_REGION`, where a change to them is reviewed
in git, and refuses a key whose wrapped target differs. Its local OpenBao holds only the key pair,
at `filone/backup-target`. FIL-1599 and FIL-1745 read both when they render their configuration. Both uploaders must send `Content-MD5` or
an `x-amz-checksum-*` header, because Object Lock refuses a put without one; WAL-G, AWS CLI v2 and
current AWS SDKs do so by default. WAL-G must run with `S3_RETENTION_PERIOD` unset, so the bucket's
default retention applies.

Freshness alerts for both kinds of backup arrive with FIL-1599 and FIL-1745. An alert now would fire
with nothing uploading.

[RFC 37]: https://github.com/fil-one/RFC/pull/37
