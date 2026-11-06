# Onboarding a regional appliance

A FilOne Appliance needs two things from a central stage: the transit key its local OpenBao seals
against, and registration with sprue, hilt and the delegator. They happen at different times, with
the node's own bring-up between them, because the key must exist before the node's first boot and
the registration needs DIDs the node does not have until it has booted.

The node's half is in
[fil-forge/infra-nodes](https://github.com/fil-forge/infra-nodes). Why any of this is shaped the way
it is: [decisions/2026-08-region-onboarding.md](decisions/2026-08-region-onboarding.md).

This is a conversation, not a pipeline. Someone at Forge Central runs the two commands below and the
node's operator runs the node; each side sends the other what it cannot produce itself. Central needs
the node's egress address, then its Piri DID and proof. The operator needs the wrapped unseal token
and, in staging and prod, the wrapped backup key, then the S3 delegation that comes back.

## The order

| Step                          | Where       | What it needs                              |
| ----------------------------- | ----------- | ------------------------------------------ |
| Commit the region label       | this repo   | nothing                                    |
| Allocate the node's public IP | infra-nodes | nothing                                    |
| Mint the credentials          | this repo   | that IP                                    |
| Deliver the wrapping tokens   | a person    | the node operator                          |
| Boot the node, generate keys  | infra-nodes | the wrapping tokens                        |
| Register the node             | this repo   | the node's Piri DID, its URL and its proof |
| Install the returned proof    | infra-nodes | the delegation registration returns        |

## Adding a region

Add the appliance's region label to `appliance_regions` in the stage's
`terraform/envs/<stage>/platform/terraform.tfvars`, and merge:

```hcl
appliance_regions = ["us-east-9"]
```

The region label is the appliance's virtual S3 region, not an AWS one. It has to match the node's
Ingot `region:` config and what clients sign with, or requests fail without naming the cause.

The apply creates the transit key `appliance-unseal-us-east-9` and a policy of the same name
granting `update` on exactly that key's encrypt and decrypt paths. In staging and prod it also
creates the IAM user `forge-nodes-backup-<stage>-us-east-9`, which can write under `us-east-9/` in
the stage's backup bucket. Confirm the key:

```bash
tofu -chdir=terraform/envs/dev/platform output appliance_keys
```

That list is reconciled against the committed one on every apply. A key in OpenBao that no list
names fails the apply rather than being deleted or ignored, so a mistyped label stops the pipeline
instead of stranding a node.

## The stage's plc directory

Ingot resolves and creates `did:plc` identities against the stage's plc, which answers on a public
hostname:

```
https://plc.<hostname suffix>
```

So `https://plc.latest.dev.fil-forge.com` in dev. The name follows from the stage, and
`tofu -chdir=terraform/envs/dev/apps output service_urls` prints it alongside the rest. The route
carries no authentication, because a `did:plc` operation is signed by the DID's own rotation key:
anyone can create a DID there, and nobody but the holder can move one.

sprue, hilt and swarf reach the same service over private DNS inside the VPC, so the public hostname
is the appliance's path and not theirs.

## Minting the credentials

The unseal token is bound to the node's egress address, so this waits until the node's own apply
has allocated its Elastic IP.

```bash
make mint-appliance-credentials STAGE=dev REGION=us-east-9 NODE_IP=203.0.113.7
```

The script mints two credentials: the unseal token, and in staging and prod the access key the node
writes its backups with. It reads first and prints what it would do for each, as `make fund-payer`
does, and mints after you confirm. What it prints at the end is a **wrapping token** per credential
it minted:

```
Give the node operator this unseal-token wrapping token:

    s.XXXXXXXXXXXXXXXXXXXX

Give the node operator this backup-key wrapping token:

    s.YYYYYYYYYYYYYYYYYYYY
```

Each credential stays inside central OpenBao until the node claims it, so neither travels. For the
unseal token only the accessor is stored, at
`/forge-central/<stage>/appliance/<region>/unseal-token.accessor`, which is enough to revoke the
token later and not enough to use it. For the backup key only IAM holds it, and the script prints
its ID with the bucket, prefix and AWS region for your record. In dev, which takes no backups, the
script reports the backup key as not applicable.

The script is safe to re-run. It skips a credential the region already holds and mints only what is
missing, so it is also how an appliance that predates the backup key gets one: a plain run skips
the live unseal token and mints the backup key.

### Delivering them

Send the wrapping tokens to whoever operates the node. Chat is acceptable: each can be spent once,
expires in 24 hours, and once spent or expired is inert wherever it was pasted. A view-once
1Password link is better and keeps them out of channel history; use one when it is easy.

What the operator does with them is in infra-nodes'
[runbook](https://github.com/fil-forge/infra-nodes/blob/main/docs/RUNBOOK.md), under "Bringing up a
node": `provision-platform.sh` asks for the unseal-token wrapping token, exchanges it at central and
stores what comes back `0400` root, and on a node that takes backups `provision-backups.sh` does the
same for the backup key and stores it in the node's own OpenBao. The node has no `bao` binary of its
own, so every OpenBao command there runs inside the container.

**If the node cannot exchange a token, somebody else spent it.** Treat it as a compromise rather
than a retry. For the unseal token, re-run the mint with `MINT_ARGS=--reissue-unseal-token`,
which revokes the token that was taken. For the backup key, re-run it with
`MINT_ARGS=--reissue-backup-key`, which deletes the key in IAM before minting another. Then find out
who could read the channel.

### Minting again

A region that already holds a credential is skipped, because two standing credentials for one node
is a state nothing can reason about. If the unseal token was never delivered, or leaked:

```bash
make mint-appliance-credentials STAGE=dev REGION=us-east-9 NODE_IP=203.0.113.7 MINT_ARGS=--reissue-unseal-token
```

That mints a replacement and then revokes the old token. A node still using it stops being able to
unseal at its next restart.

If the backup key was never delivered, or leaked:

```bash
make mint-appliance-credentials STAGE=staging REGION=eu-central-3 NODE_IP=203.0.113.7 MINT_ARGS=--reissue-backup-key
```

That deletes the old key first, so the node's uploads fail until it stores the new one with
`provision-backups.sh --replace`. The two flags are independent, so replacing one credential never
rotates the other.

No flag is needed when the recorded unseal token has simply lapsed, which is the ordinary state of a
node that has been offline longer than the 72-hour renewal period. The script reports that and
mints.

## What the node does with the backup key

Staging and prod keep each appliance's backups in `forge-nodes-backups-<stage>-<account id>`, under
the region's own prefix. Why it is built this way is in
[decisions/2026-11-appliance-backup-target.md](decisions/2026-11-appliance-backup-target.md). The
node's backup jobs ([FIL-1599](https://linear.app/filecoin-foundation/issue/FIL-1599) for Postgres,
[FIL-1745](https://linear.app/filecoin-foundation/issue/FIL-1745) for OpenBao) depend on the
following:

- The node keeps the target in its `node.env`, as `BACKUP_S3_BUCKET`, `BACKUP_S3_PREFIX`
  (`<region>/`) and `BACKUP_S3_REGION`. Copy them from what the mint script prints for your record.
- The node stores only the key pair in its local OpenBao, at `filone/backup-target`, never in a
  plain file. The unwrapped payload has five fields: `access_key_id` and `secret_access_key`, which
  it stores, and `bucket`, `prefix` and `aws_region`, which it checks against `node.env` and refuses
  the key on a mismatch.
- WAL-G writes under `WALG_S3_PREFIX=s3://<bucket>/<region>/postgres`. Leave `S3_RETENTION_PERIOD`
  unset, so the bucket's 35-day compliance lock applies. The key can read back only the timeline
  history files under that prefix, which WAL-G checks before overwriting one, and can delete
  nothing.
- Raft snapshots go under `<region>/openbao/` and need nothing but `PutObject`.
- Both uploaders must send `Content-MD5` or an `x-amz-checksum-*` header, because Object Lock
  refuses a put without one. WAL-G, AWS CLI v2 and current AWS SDKs do by default; keep that
  behaviour on.
- A put to a key that already exists adds a version and leaves the earlier one locked. WAL-G
  re-archives a WAL segment when a retried upload already reached S3, so expect some keys to carry
  more than one version.
- A failed unwrap of the backup key is a compromise, as for the unseal token: delete the key in IAM
  and run the mint with `MINT_ARGS=--reissue-backup-key`.

To check what a writer can and cannot do, run this with administrator credentials:

```bash
scripts/check-appliance-backup-access.sh staging eu-central-3
```

It creates a temporary second key on the region's user, tries every allowed and every refused call,
reads back the lock and lifecycle configuration, and deletes the key. Each run leaves a few small
locked objects under `<region>/check/` that expire after 36 days.

## Registering the node

Run this once the appliance has provisioned its keys, so its Piri DID exists. It needs the proof the
appliance signed with its own Piri key, which central never holds.

```bash
make onboard-appliance STAGE=dev REGION=us-east-9 \
  PIRI_DID=did:key:z6Mk… \
  PIRI_URL=https://piri-0.latest.dev.fil-forge.com \
  PIRI_PROOF=piri-proof.txt \
  ONBOARD_ARGS="--proof-out ingot-proof.txt"
```

The Ingot identity is not asked for. Central derives the RFC identity
`did:web:s3.<REGION>.<ingot_hostname_suffix>` from the region being onboarded
and the stage configuration. For the example above it is
`did:web:s3.us-east-9.latest.dev.filonecontent.com`. The node operator therefore
has nothing to send or mistype, and multiple regions in one stage receive
distinct identities. The appliance can rotate its key afterwards because its
DID document publishes the current one without changing the DID.

hilt and sprue each cache a resolved DID document for three hours, in process and with no eviction
API, so a restart is the only way to clear one:

```bash
aws ecs update-service --cluster fc-$STAGE --service fc-$STAGE-hilt --force-new-deployment
aws ecs update-service --cluster fc-$STAGE --service fc-$STAGE-sprue --force-new-deployment
```

That matters on every Ingot key rotation. The DID does not move, but the key in the document does,
and until both services re-resolve they verify against the old one.

Five things happen, and each one has a failure that names nothing useful if it is skipped:

- The **delegator's allow list** gets the Piri DID. Without it, `piri init` step 4 asks the
  delegator for approval and is refused with a `403`.
- **sprue** gets the Piri registered at its public URL, with a weight and the delegation the
  appliance signed. Without it, uploads fail with
  `CandidateUnavailable: no storage providers available`.
- **hilt** gets the Ingot registered for the region, with the Piri as its storage node. Without the
  registration, hilt rejects tenant creation for that region and every `/s3/*` call the Ingot makes.
  Without the node, the region's buckets use sprue's default routing and their data can land on any
  storage node in the stage.
- **hilt signs the S3 delegation** the Ingot presents back to it, which is the one piece only central
  can produce.
- **Central records the Piri DID under the region.** sprue has no region on its provider row and
  hilt keeps only the DID of the routing policy that holds its nodes, so this is the only readable
  record of that association. It is also the node set hilt is given: hilt replaces the set rather
  than adding to it, so a region's second Piri is sent together with its first, and a provider
  registered before hilt took storage nodes is repaired from the same record.

The record is a temporary SSM-backed list, with one parameter for each Piri DID.
Region retirement will use it to find the Piri providers that need
deregistration. [FIL-1130](https://linear.app/filecoin-foundation/issue/FIL-1130)
tracks replacing it with a proper registry of Piri nodes by region.

The script reads all three services first and prints what it found before writing anything. A second
run is safe: it performs only what is missing and returns the delegation issued the first time,
byte for byte, because a delegation carries a random nonce and re-issuing one would produce
something central no longer recognises.

The sprue weights are the exception. They are written on every confirmed run, from the request or
from the 100/100 default, so a rerun of a provider whose weights were tuned afterwards has to carry
the current values in `ONBOARD_ARGS`, as `--weight` and `--replication-weight`.

So is the Piri delegation, whenever the request carries `PIRI_PROOF`. sprue offers no read of the
delegation it holds, so a rerun replaces it with the one in the request. That is how a delegation
the node reissued reaches sprue: when infra-nodes adds a command to it, run `keygen.sh` and then
`onboarding-request.sh` on the node, and onboard again with the new proof. A rerun without
`PIRI_PROOF` leaves sprue's copy alone.

### When it refuses

Two conditions stop the run, and both need a decision rather than a retry.

**hilt has the Ingot registered for a different region.** hilt raises the same "already registered"
error whether the DID is held for this region or another one, and it ships no command to move a
provider. Trusting that error is what smelt did once, and the mismatch it hid broke every request
afterwards. `make retire-region` on the region hilt names is what clears such a row.

**sprue has the Piri registered at a different endpoint.** Re-registering would move where uploads
are sent, so deregister the provider deliberately first if that is what you mean.

### The proof

What comes back is hilt's delegation to the appliance's Ingot, authorising `/s3/request/authorize`
and the four `/s3/bucket/*` commands. Hand it to the appliance as the proof its Ingot presents. It is
not a secret: a delegation is useless without the audience's own key. The `--proof-out` in the
example above writes it to a file; without that flag it goes to stdout.

## Changing an appliance's Ingot DID

When the derived Ingot DID changes, retire the region's old identity before re-onboarding:

```bash
make retire-region STAGE=dev REGION=us-east-9
```

It deletes hilt's provider row for the region, the buckets that region served, the delegations
naming any of them, and the delegation central stored for the old audience. It reads and prints all
of that first, and asks before deleting anything. It leaves sprue, the delegator and the node's
unseal credential alone, so Piri's identity and the node's ability to unseal are unaffected.

Organisations survive a retirement. A tenant is not tied to a region, so it keeps its buckets
elsewhere along with its members and access keys. What it loses is the buckets the retired region
held, and the data in them, which went with the appliance.

Without it a re-onboard reports success and changes nothing. The stored delegation is keyed by the
appliance's prefix and the proof's name, neither of which mentions the audience, so onboarding finds
the old one and returns it. The log line to look for on the re-onboard is **"issued hilt's S3
delegation to the appliance"** with the new audience; **"returning the delegation issued earlier"**
means the retire did not happen.

A `tofu destroy` of the stage does not clear it either. See [What survives a
destroy](../README.md#what-survives-a-destroy).

The full sequence is retire, re-onboard with `--proof-out`, force a new deployment of hilt and sprue
so they re-resolve the DID document, then hand the new proof to the node operator for
`store-hilt-proof.sh` and `deploy-apps.sh`.

## Granting Ingot a new hilt command

The delegation's commands are fixed when it is issued. When Ingot starts invoking a new command on
hilt, add it to `HiltIngotS3Proof` in `internal/keygen/proofs.go` and deploy the provision Lambda.
Until then hilt refuses that command with "is not issued by subject and has no proofs", and Ingot
answers the S3 request with a 500.

Then re-onboard each region. Onboarding compares the stored delegation's commands with the current
list and reissues it when one is missing; the log line is **"the stored delegation lacks commands
Ingot invokes, reissuing the appliance's delegation"**. Pass `--proof-out` and hand the new proof to
the node operator for `store-hilt-proof.sh` and `deploy-apps.sh`. The old proof keeps working for
the commands it grants until the node swaps it.

## Retiring a region

Move the label from `appliance_regions` to `retired_appliance_regions` in the same commit, and
merge:

```hcl
appliance_regions         = []
retired_appliance_regions = ["us-east-9"]
```

The apply revokes the node's unseal token, deletes its token role, deletes its parameters and
destroys its transit key. **This is not reversible.** The node behind that key can never unseal
again, and everything on its disks stays encrypted with a key that no longer exists.

In staging and prod the same apply deletes the region's backup writer user and its access key, so
the node stops writing backups within seconds, even while it keeps running. The backups it already
wrote stay locked and expire on schedule, 36 days after each was written; nothing can remove them
sooner.

An apply that fails partway has revoked the token and left the key standing, which is what brings
the region back to the next apply to finish the rest. Read what the phase reported rather than
assuming the cleanup completed.

Keep the retired label in the list. While the key still stands, a key named by neither list fails
the apply, and that refusal is what protects every other region's key from a typo. Once the key is
destroyed the check has nothing left to catch, so from then on the label is a note to the next
reader: dropping it and adding it back to `appliance_regions` creates a fresh key under a name whose
node was retired.

### Retiring a node you no longer trust

The apply takes effect at the node's next unseal. Transit unseal happens at boot, so an appliance
that is already running holds its key in memory and keeps serving traffic until it restarts, which
an operator you are retiring against has no reason to do.

Evicting such a node starts at sprue, hilt and the delegator, and the apply comes last. None of the
three has tooling for it yet, so every step is manual:
[FIL-1090](https://linear.app/filecoin-foundation/issue/FIL-1090) carries the procedure and the
tooling, and [FIL-1091](https://linear.app/filecoin-foundation/issue/FIL-1091) hilt's half of it.
