# Region onboarding: how an appliance is admitted to a stage

A FilOne Appliance cannot boot or serve traffic until central does two things for it: create the
transit key its local OpenBao seals against, and register its identities with sprue, hilt and the
delegator. This document records the choices behind the automation that does both, and what each
one costs.

The companion document is
[infra-nodes' initial design](https://github.com/fil-forge/infra-nodes/blob/main/docs/decisions/2026-08-initial-design.md),
which decides the node's half.

## Two touchpoints, not one

Onboarding cannot be a single operation:

- The transit key has to exist before the node's first boot, because OpenBao refuses to start without it.
- The node registration need the node's DIDs, which do not exist until the node has provisioned its own keys, which it can only do after it boots.

So there are two operator steps with the node's bring-up between them.

## A person runs both halves

Onboarding is a conversation between someone at Forge Central and the node's operator, and the
tooling serves that conversation rather than replacing it.

- Central needs the node's egress CIDR to mint the unseal token, and its two DIDs and Piri proof to register it.
- The operator needs the wrapped token, and the S3 delegation that comes back.

Each script takes what the other side sent and prints what to send in return.

Nothing here is built for an appliance that onboards itself. The two commands are run by a person who
knows which appliance they are admitting, and the exchange in the middle is where a third-party
operator is identified as someone the network is willing to seal a region for.

## The writes happen in a Lambda

sprue's and hilt's admin operations are UCAN invocations signed by _that service's own identity
key_, and those keys live only in SSM, readable by the provision Lambda and nothing else. Signing
them anywhere but inside AWS would mean copying a service identity key to an operator's machine,
which is the one thing this deployment is built to avoid. So the writes run as a provision phase
and an operator script invokes it, the same arrangement `scripts/fund-payer.sh` uses for money.

Two alternatives, with their strongest cases:

**ECS Exec into the running tasks** reimplements nothing. `aws ecs execute-command` would run the
same `sprue client admin` and `hilt client admin` commands the services ship, so their invocation
format stays correct for free as they evolve, which is exactly what the Lambda gives up. It was
rejected because it needs `enable_execute_command` on every service, which is a documented human
shell into a production task, and it still covers neither the DynamoDB write nor the transit key.
The shell would be an addition to the onboarding tooling rather than a replacement for it.

**Admin operations exposed over the ALB behind authentication** is the only option an appliance
could call for itself. It was rejected on both counts: onboarding is deliberately a person-to-person
exchange, and building the authentication for a caller that does not exist is work with nothing
behind it.

## Transit keys are reconciled from two committed lists

`appliance_regions` and `retired_appliance_regions` in each stage's `terraform.tfvars` are the
source of truth for which appliances a stage can unseal. Both reach the vault phase in its
invocation input, and `aws_lambda_invocation` re-invokes when its input changes, so adding or
retiring a region is a reviewed one-line diff that reconciles on merge with no trigger to bump.

Removal is automated in the same pass, because a key that exists in OpenBao and in no committed
file means git no longer describes the system. What makes that safe is the refusal: a key matching
`appliance-unseal-*` that appears in neither list **fails the phase**, naming the region and both
lists. A label that appears in both lists fails the same way, before anything is written, since a
region is either live or retired. Retiring is therefore an explicit move from one list to the other, and the accident this
guards against is specific. Deleting a transit key permanently destroys the node behind it, dev
applies on merge with nobody confirming, and under a single-list scheme a mistyped region label
would read as "destroy that key, create this one" and be obeyed.

The cost is a second list to keep, and one that only grows. A retired label stays committed
forever, because dropping it is what the refusal is there to catch.

Retirement fires the kill lever in a fixed order: revoke the node's unseal token, delete its token
role, delete its parameters, destroy the transit key. Revoking first means a retirement that fails
halfway has still contained the node it was meant to contain. Destroying the key last makes it the
record of whether the sequence finished, since the key's presence is what puts the region back in
front of the next apply; deleting it earlier would strand every step after it with nothing left to
notice.

Retirement does not deregister the node from sprue, hilt or the delegator, and the kill lever
contains a node at its next unseal rather than immediately: an appliance that is already unsealed
holds its key in memory and keeps receiving traffic until it restarts. Evicting a live node
therefore starts at the registries, with sprue's deregister command and a delete against the
delegator's allow list, and fires the lever after. Those steps stay manual; hilt's row is the open
decision recorded below.

## The unseal token is delivered wrapped

The Lambda mints the node's periodic token and immediately hands it to OpenBao's response wrapping,
so what comes back to the operator is a single-use wrapping token with a short TTL. That is what
travels to the node's operator, who may be a third party. On the node, one `bao unwrap` against
`ssm.<stage>` yields the real token, which goes straight into a root-only `0400` file.

The real token therefore never transits any channel, any laptop or any third-party service. What
travels can be spent exactly once, and interception is _detectable_: an attacker who unwraps first
makes the legitimate unwrap fail, which is [RFC 21]'s own requirement that any use of a stolen boot
credential be visible at central. A wrapping token left behind in a chat log is inert once spent or
expired.

This is what makes ordinary channels acceptable for the hand-off, chat included. A view-once
1Password link is better hygiene and the runbook recommends it, narrowing the window and keeping
the artifact out of channel history, but the tooling does not depend on it.

The wrap TTL defaults to 24 hours, which is how long the hand-off may sit unclaimed: long enough for
a delivery across time zones, short enough that a leak nobody noticed expires on its own. An expired
wrap costs another mint, which is cheap.

One discipline the design requires: a failed legitimate unwrap inside the wrap TTL is a compromise,
not a hiccup, and the mint time in the Lambda's logs is what separates the two cases. Revoke by the
stored accessor, mint again, and find out who read the channel. The runbook says so where the step
is.

infra-nodes' original design doc had rejected wrapped enrollment as buying nothing at a single
first-party node, and that was right for the case it considered. With a third party on the other
end of the hand-off, the custody and detectability arguments both return.

## The token is minted through a per-region token role

CIDR binding is a property of a token _role_, not of the token-create call. OpenBao's token store
sets a new token's bound CIDRs from `role.TokenBoundCIDRs`, or inherits the parent's, and an orphan
token has no parent to inherit from. So `auth/token/create-orphan` with a `token_bound_cidrs`
parameter does not bind anything: the parameter is not in that endpoint's schema, and the token
comes out usable from anywhere.

Minting therefore writes `auth/token/roles/appliance-unseal-<region>` first, carrying `orphan=true`,
`token_period`, `token_bound_cidrs` and `allowed_policies`, and mints through
`auth/token/create/appliance-unseal-<region>`. The role is written at mint time rather than by the
vault phase, because its CIDR is the node's Elastic IP and that address does not exist until the
node's own apply has run.

`token_no_default_policy` is set, so the token carries the region's policy and nothing else. That is
why the policy grants `auth/token/renew-self` explicitly: without the default policy, a periodic
token that could not renew itself would die at the end of its first period.

The CIDR check reads the client address the listener reports, and the appliance reaches OpenBao
through the ALB, which connects from its own address. A listener checking raw connections would see
the ALB and refuse every bound token. The listener therefore trusts `X-Forwarded-For` from the
ALB's subnets and nothing wider: the ALB appends the caller's real address as the final hop, so a
forged header loses to the append, and a direct in-VPC client carries no header and is checked on
its own address. Trusting the whole VPC instead would let any workload inside it claim the node's
address.

## The token is orphan, periodic, 72 hours, CIDR-bound

Orphan so revoking an operator's own token does not cascade into the node. CIDR-bound to the node's
Elastic IP so the credential is worthless anywhere else. The token store evaluates that binding
against the address its listener sees, and the node arrives through the public ALB, so central
OpenBao is configured to take the client address from `X-Forwarded-For` and to believe that header
only on connections from the ALB's own subnets. Without it the address seen is the ALB's, and every
renewal and transit call from the node is rejected. Periodic so it renews forever with no
expiry cliff, which leaves only the period to choose: how long the node may fail to renew before
its token dies and the whole delivery ceremony repeats.

72 hours, so a node that loses connectivity over a weekend comes back on its own, while a node that
is abandoned or decommissioned fails closed within days. 24 hours would strand any outage longer
than a day and buys little, since revocation is immediate at any period. A month would keep a
forgotten node's credential renewable long past the point anyone was watching it.

The node's renewal timer runs hourly regardless, so the period is a tolerance for outages rather
than a schedule.

## Only the accessor is stored

`/forge-central/<stage>/appliance/<region>/unseal-token.accessor` holds the token's accessor as a
plain String. An accessor cannot authenticate: it can look a token up and revoke it, which is
exactly what retirement and reissue need. The token itself is stored nowhere in AWS.

That makes minting the one operation in this repository that is deliberately not idempotent. A
second run would leave two standing credentials for one node, so a region whose accessor is
recorded and whose token still lives is refused unless the operator passes `--reissue`, which
revokes the old token before minting the new one. A lookup that cannot answer at all stops the
phase, because minting on an unanswered question is how a node ends up with the second credential
the refusal exists to prevent.

A mint writes the token first and the accessor second, so a Lambda that dies between the two leaves
a token no parameter records, and the retry mints a second one. The window is accepted because the
stranded token is contained without anyone acting: its wrapping token was returned to nobody, it is
bound to the node's own address, it carries only the region's unseal policy, and unrenewed it dies
at the end of its 72-hour period. A failed write rather than a crash is not in that window: the
phase revokes the token it just minted, turning an unrecordable token into a failed mint the
operator can run again.

A reissue revokes the old token last, after the replacement has been minted and recorded. Revoking
first would leave the appliance with no renewable credential whenever the mint that was supposed to
replace it failed, and the node would stop being able to unseal at its next restart because of a
reissue that produced nothing. The one state this ordering can still leave is an old token that is
live and no longer on record, which is why the error names its accessor: the node keeps renewing
that token until someone revokes it by hand.

It is also the one phase whose response carries a secret, where every other phase response is
documented as safe for anyone with Terraform state access. The phase is therefore never wired to an
`aws_lambda_invocation`, and both the code and this document say so.

## The client packages are imported rather than reimplemented

The Lambda calls sprue and hilt through their published Go client packages, so the invocation
format is the services' own rather than a reimplementation that could quietly diverge. The modules
are still pinned independently of the image digests the bump workflow deploys, so a version skew
between client and service remains possible; it shows up as a failed admin call rather than a
silent mismatch, and the phase reads its writes back. Hand-rolling the four commands on ucantone, which
is already a dependency, would keep the Lambda image smaller and was the fallback if the dependency
tree proved unreasonable for a Lambda.

It did not. `sprue/pkg/client` and `hilt/pkg/client` reach only ucantone, libforge, zap and
cbor-gen; the first and last are already dependencies here. Neither pulls echo, cobra, viper, fx,
docker or testcontainers, all of which sit in those repositories' module requirements but on paths
these packages do not import. The heavy machinery is in their `cmd/client/lib` packages, which load
a service config through uber-fx, and nothing here touches those.

Adding hilt raises the module's `go` directive to 1.26.4, which is what hilt's own go.mod requires.
CI installs the toolchain from `go-version-file: go.mod`, so nothing there needs changing, but
building this repository now needs Go 1.26.4 or newer.

What makes the light path work is the constructors' shape. Both take a plain `ucan.Issuer`:
`client.New(serviceDID, endpoint, issuer, logger)` and
`NewAdminClient(issuer, serviceURL, logger)`. An issuer is built directly from the service's PEM
read out of SSM, so the Lambda signs as sprue or hilt without either service's configuration
loader.

## Operator scripts live here; the node's caller lives in infra-nodes

`scripts/mint-appliance-token.sh` and `scripts/onboard-appliance.sh` both ship here, in
`fund-payer.sh`'s shape: dry run, printed plan, typed confirmation, then the run that changes
something. The steps an operator follows, and the delivery and compromise-handling rules around
them, are in [docs/appliance-onboarding.md](../appliance-onboarding.md). Two scripts rather than one command with subcommands, because they take different inputs,
and handle secrets differently.

## A mismatch is a refusal, not a repair

The onboard phase reads all three services before it writes, and it distinguishes two kinds of
disagreement. Something absent is an action: it gets created. Something present but different is a
blocker, and the run performs nothing at all.

That split exists because every fix for a mismatch destroys something. hilt ships no command to move
a provider between regions, so correcting its row means editing its database. Re-registering a
provider with sprue at a new endpoint changes where uploads are sent. Neither is a decision tooling
should take on a dry run the operator approved for something else.

The hilt case is the one with history. hilt raises the same error, ErrProviderExists, for a DID
registered under the requested region and for one registered under a different region, so tolerating
that error accepts a mismatch that breaks every subsequent request. smelt hit exactly this after a
region rename, and its script now verifies the row. So does this phase, twice: once when reading, and
again after its own write, because a write that reported success is not evidence of what it did.

A region label this stage has never minted an unseal token for is refused before anything is read.
hilt would otherwise register the Ingot under a mistyped `--region` permanently, and that row is the
one mismatch with no repair short of editing hilt's database. The recorded token accessor is the
evidence the label is real: an appliance cannot hold the DIDs this phase is given without having
unsealed with a token minted for exactly that label.

The allow list is written directly to DynamoDB rather than through the delegator's
`registrar store allow-did` command. The command needs a shell in the delegator's task, and it runs
as a Fargate task in a private subnet with ECS Exec off. The table takes a single `did` hash key, so
the item is unambiguous, and it carries the same `added_by`, `added_at` and `notes` fields the
delegator's own writer adds.

## Weights are rewritten on every run

The two provider weights are set on every run that gets past the plan, where every other write
happens only when its target is missing. They are two integers derived from the request, so writing
them again cannot change what a previous run established, and it repairs a provider left with
whatever defaults sprue assigned. The proof is the opposite case, written once and read back
afterwards, because a delegation carries a random nonce and re-issuing one produces bytes central
would no longer recognise as the delegation it issued.

The one thing that does force a reissue is a rotated hilt identity, which leaves every delegation the
old key signed unverifiable: hilt's did:web document then publishes only the new key. The signing
key's did:key is stored beside the proof, so a later run compares the two and reissues when they
differ. The seed phase tracks the same dependency for the startup proofs.

## OpenBao tests run in-process

`internal/vaultinit`'s tests hand the fake server to the real OpenBao client through a custom
`http.RoundTripper` rather than an `httptest` listener. The client still builds the URL, sets its
headers, serialises the body and parses the response; only the socket is skipped, and no assertion
depended on it.

The reason to prefer it is that a suite needing no listener runs in more places, including sandboxes
that deny `bind`. It earned that immediately: with the tests running, the fake was found to be
answering the wrong methods on four paths, since `Logical().Write` is a `PUT` while the token
accessor endpoints are `POST`.

## Decisions still open

Recorded here as they are settled during implementation and review.

- How hilt's provider row should be removed when a region is retired. sprue has a deregister command
  and the delegator's allow list is a delete against a table this already writes; hilt has neither,
  so that row means either a change in hilt or a delete against its database.

[RFC 21]: https://github.com/fil-one/RFC/pull/21
