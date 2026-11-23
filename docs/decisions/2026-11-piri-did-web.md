# Piri is the did:web of its public URL

A Piri is identified by the `did:web` of the URL it serves at: a Piri at
`https://piri-0.eu-central-3.staging.fil-forge.com` is
`did:web:piri-0.eu-central-3.staging.fil-forge.com`. Piri derives the DID from its configured public
URL and publishes its signing key in a DID document at `/.well-known/did.json` on that host. The
change itself is [fil-forge/piri#243](https://github.com/fil-forge/piri/issues/243).

The alternative is the `did:key` of its signing key, which Piri first shipped with. That makes the
key the identity: a key that leaked or was lost can only be replaced by becoming a different node,
with a new allow-list entry, a new provider row in sprue and every location commitment the old node
issued left pointing at an identity nobody answers for. With a `did:web` the DID stays put and the
document says which key is current, the same property that settled
[Ingot's identity](2026-08-region-onboarding.md#an-appliances-ingot-is-a-region-qualified-didweb).

## What central does differently

- **Onboarding takes the `did:web`.** The onboard phase refuses a Piri DID of any other method, and
  refuses one that is not the `did:web` of the Piri URL in the same request. A Piri cannot have any
  other DID, so a mismatch is a mistyped request.
- **The region record is named by host.** Central records each region's Piri DIDs in SSM, one
  parameter per DID. A DID cannot be a parameter name, so the host the DID names is the name:
  `appliance/<region>/piri/<host>`. The value is the full DID, as before.

## What it costs

- **The hostname is the identity.** Renaming a Piri makes it a new node to the network, to be
  onboarded again. Whoever controls the hostname, and the certificate for it, can publish a key for
  the DID.
- **Verifying a Piri needs its host to be reachable.** A `did:key` verifies with no network. A
  `did:web` is resolved by fetching the document, so a service that has not cached it cannot verify
  the Piri's signatures while the host is down.
- **Every existing Piri gets a new DID.** A node that takes the Piri version with this change has to
  be onboarded again under its `did:web`.

Replacing a key in a running network needs more than the DID document: verifiers have to keep
accepting commitments the old key signed before it was replaced. That is tracked in the same issue
and is not part of this change.
