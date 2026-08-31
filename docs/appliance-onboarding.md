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
the node's egress address, then its Piri DID and proof. The operator needs the wrapped unseal token,
then the S3 delegation that comes back.

## The order

| Step                          | Where       | What it needs                              |
| ----------------------------- | ----------- | ------------------------------------------ |
| Commit the region label       | this repo   | nothing                                    |
| Allocate the node's public IP | infra-nodes | nothing                                    |
| Mint the unseal token         | this repo   | that IP                                    |
| Deliver the token             | a person    | the node operator                          |
| Boot the node, generate keys  | infra-nodes | the token                                  |
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
granting `update` on exactly that key's encrypt and decrypt paths. Confirm it:

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

So `https://plc.dev.forge-sandbox.fil.one` in dev. The name follows from the stage, and
`tofu -chdir=terraform/envs/dev/apps output service_urls` prints it alongside the rest. The route
carries no authentication, because a `did:plc` operation is signed by the DID's own rotation key:
anyone can create a DID there, and nobody but the holder can move one.

sprue, hilt and swarf reach the same service over private DNS inside the VPC, so the public hostname
is the appliance's path and not theirs.

## Minting the unseal token

The token is bound to the node's egress address, so this waits until the node's own apply has
allocated its Elastic IP.

```bash
make mint-appliance-token STAGE=dev REGION=us-east-9 NODE_IP=203.0.113.7
```

The script invokes the Lambda twice, as `make fund-payer` does: the first call reads OpenBao and
prints what it would do, and the second mints after you confirm. What it prints at the end is a
**wrapping token**, not the credential:

```
Give the node operator this wrapping token:

    s.XXXXXXXXXXXXXXXXXXXX
```

The credential itself stays inside OpenBao until the node claims it, so it never travels. Only the
accessor is stored, at `/forge-central/<stage>/appliance/<region>/unseal-token.accessor`, which is
enough to revoke the token later and not enough to use it.

### Delivering it

Send the wrapping token to whoever operates the node. Chat is acceptable: it can be spent once,
it expires in 24 hours, and once spent or expired it is inert wherever it was pasted. A view-once
1Password link is better and keeps it out of channel history; use one when it is easy.

What the operator does with it is in infra-nodes'
[runbook](https://github.com/fil-forge/infra-nodes/blob/main/docs/RUNBOOK.md), under "Bringing up a
node": `provision-platform.sh` asks for the wrapping token, exchanges it at central and stores what
comes back `0400` root. The node has no `bao` binary of its own, so every OpenBao command there runs
inside the container.

**If the node cannot exchange the token, somebody else spent it.** Treat it as a compromise rather
than a retry: re-run the mint with `TOKEN_ARGS=--reissue`, which revokes the token that was taken,
and find out who could read the channel.

### Minting again

A region that already has a live token is refused, because two standing credentials for one node is
a state nothing can reason about. If the previous token was never delivered, or leaked:

```bash
make mint-appliance-token STAGE=dev REGION=us-east-9 NODE_IP=203.0.113.7 TOKEN_ARGS=--reissue
```

That revokes the old token first. A node still using it stops being able to unseal at its next
restart.

No flag is needed when the recorded token has simply lapsed, which is the ordinary state of a node
that has been offline longer than the 72-hour renewal period. The script reports that and mints.

## Registering the node

Run this once the appliance has provisioned its keys, so its Piri DID exists. It needs the proof the
appliance signed with its own Piri key, which central never holds.

```bash
make onboard-appliance STAGE=dev REGION=us-east-9 \
  PIRI_DID=did:key:z6Mk… \
  PIRI_URL=https://piri.dev.forge-sandbox.fil.one \
  PIRI_PROOF=piri-proof.txt \
  ONBOARD_ARGS="--proof-out ingot-proof.txt"
```

The Ingot identity is not asked for. It is `did:web:ingot.<hostname suffix>`, so
`did:web:ingot.dev.forge-sandbox.fil.one` in dev: the hostname the node already serves, derived from
the stage, so the node operator has nothing to send and nothing to mistype. The name is per stage, so
a stage admits one appliance. The appliance can rotate that key on its own afterwards, because its
DID document publishes the current one.

hilt and sprue each cache a resolved DID document for three hours, in process and with no eviction
API, so a restart is the only way to clear one:

```bash
aws ecs update-service --cluster fc-$STAGE --service hilt --force-new-deployment
aws ecs update-service --cluster fc-$STAGE --service sprue --force-new-deployment
```

That matters on every Ingot key rotation. The DID does not move, but the key in the document does,
and until both services re-resolve they verify against the old one.

Four things happen, and each one has a failure that names nothing useful if it is skipped:

- The **delegator's allow list** gets the Piri DID. Without it, `piri init` step 4 asks the
  delegator for approval and is refused with a `403`.
- **sprue** gets the Piri registered at its public URL, with a weight. Without it, uploads fail with
  `CandidateUnavailable: no storage providers available`.
- **hilt** gets the Ingot registered for the region. Without it, hilt rejects tenant creation for
  that region and every `/s3/*` call the Ingot makes.
- **hilt signs the S3 delegation** the Ingot presents back to it, which is the one piece only central
  can produce.

The script reads all three services first and prints what it found before writing anything. A second
run is safe: it performs only what is missing and returns the delegation issued the first time,
byte for byte, because a delegation carries a random nonce and re-issuing one would produce
something central no longer recognises.

The sprue weights are the exception. They are written on every confirmed run, from the request or
from the 100/100 default, so a rerun of a provider whose weights were tuned afterwards has to carry
the current values in `ONBOARD_ARGS`, as `--weight` and `--replication-weight`.

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

It deletes hilt's provider row for the region, every tenant, bucket, access key and delegation under
it, and the delegation central stored for the old audience. It reads and prints all of that first,
and asks before deleting anything. It leaves sprue, the delegator and the node's unseal credential
alone, so Piri's identity and the node's ability to unseal are unaffected.

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
