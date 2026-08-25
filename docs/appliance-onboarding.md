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

**The merge has to carry a current provision image.** The region lists reach the Lambda in its
invocation input, and a Lambda still running an older image accepts the input, ignores the fields it
does not know and reports success having created nothing. The only symptom is an empty
`appliance_keys`. Publish and commit the digest in the same change:

```bash
make publish STAGE=dev     # writes terraform/envs/dev/platform/image.auto.tfvars
```

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

On the node, exchange it and write the result to the root-only `0400` file the node reads:

```bash
BAO_ADDR=https://ssm.dev.forge-sandbox.fil.one bao unwrap s.XXXXXXXXXXXXXXXXXXXX
```

**If that unwrap fails, somebody else spent the token.** Treat it as a compromise rather than a
retry: re-run the mint with `TOKEN_ARGS=--reissue`, which revokes the token that was taken, and find
out who could read the channel.

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
  PIRI_PROOF=piri-proof.txt
```

The Ingot identity is not asked for. It is `did:web:<region>.s3.<stage>.filonecontent.com`, derived
from the region label, so the node operator has nothing to send and nothing to mistype. The appliance
can rotate that key on its own afterwards, because its DID document publishes the current one.

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

### When it refuses

Two conditions stop the run, and both need a decision rather than a retry.

**hilt has the Ingot registered for a different region.** Since the Ingot DID is named after the
region, the two can only disagree if hilt's row was written by hand. hilt raises the same "already
registered" error whether the DID is held for this region or another one, and it ships no command to
move a provider, so such a row has to be corrected in its database by hand as well. Trusting that
error is what smelt did once, and the mismatch it hid broke every request afterwards.

**sprue has the Piri registered at a different endpoint.** Re-registering would move where uploads
are sent, so deregister the provider deliberately first if that is what you mean.

### The proof

What comes back is hilt's delegation to the appliance's Ingot, authorising `/s3/request/authorize`
and the four `/s3/bucket/*` commands. Hand it to the appliance as the proof its Ingot presents. It is
not a secret: a delegation is useless without the audience's own key. Write it straight to a file
with `ONBOARD_ARGS="--proof-out ingot-proof.txt"`.

## Retiring a region

Move the label from `appliance_regions` to `retired_appliance_regions` in the same commit, and
merge:

```hcl
appliance_regions         = []
retired_appliance_regions = ["us-east-9"]
```

The apply revokes the node's unseal token, deletes its token role, destroys its transit key and
deletes its parameters. **This is not reversible and it is not partial.** The node behind that key
can never unseal again, and everything on its disks stays encrypted with a key that no longer
exists.

Keep the retired label in the list. Removing it from both lists is what the apply refuses, and that
refusal is what protects every other region's key from a typo.

### Retiring a node you no longer trust

The apply takes effect at the node's next unseal. Transit unseal happens at boot, so an appliance
that is already running holds its key in memory and keeps serving traffic until it restarts, which
an operator you are retiring against has no reason to do.

Evicting such a node starts at the registries, and the apply comes last. Both eviction steps are
manual, and hilt's provider row has no command yet:

- **sprue** stops sending uploads once the Piri is deregistered, with `sprue client admin`.
- **The delegator** refuses the appliance's next `piri init` once its DID is deleted from the
  allow list.
- **hilt** keeps its provider row, because hilt ships no command to remove one. Correcting it means
  editing hilt's database by hand.

With those done, merge the retirement and the node cannot come back after any restart.
