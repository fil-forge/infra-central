# Delivering a regional appliance's unseal token

A regional appliance seals its local OpenBao against central, and authenticates here at boot to
unseal. This is how that credential is minted and handed over. The design behind it is in
[docs/decisions/2026-08-region-onboarding.md](decisions/2026-08-region-onboarding.md).

Two people are involved throughout: someone at Forge Central who runs the script, and whoever
operates the node. Central needs the node's egress address before it can mint; the operator needs
the wrapping token that comes back.

## Before you mint

The region's transit key must already exist. It is created by the vault phase from
`appliance_regions` in the stage's `terraform.tfvars`, so a region that has not been committed and
merged fails at the first invocation rather than being created on the spot.

The node's Elastic IP must already be allocated, which is its own apply in infra-nodes. The token is
bound to that address as a `/32` and is worthless anywhere else, which is what makes an imaged disk
replayed elsewhere fail to unseal.

## Mint

```
scripts/mint-appliance-token.sh --region us-east-9 --node-ip 203.0.113.7
```

The script reads OpenBao and prints what would happen, waits for you to type `mint`, and then mints.
What comes back is not the token: it is a single-use wrapping token with a 24-hour TTL that the node
exchanges for the real one.

A region that already has a live token is refused. Two standing credentials for one node is a state
nothing can reason about, and nothing afterwards would say which of them the node is using. Pass
`--reissue` to revoke the existing token and mint a replacement.

## Hand it over

Send the wrapping token to the node's operator. Chat is acceptable, because the credential itself is
still inside OpenBao and what travels can be spent exactly once. A view-once 1Password link is
better: it narrows the window and keeps the artifact out of channel history.

Send the address alongside it. The script prints both.

## On the node

```
BAO_ADDR=https://ssm.<stage suffix> bao unwrap <wrapping token>
```

The result goes straight into the root-only `0400` file the node reads, and nowhere else. It is
never stored in AWS, and central cannot print it again.

## A failed unwrap is a compromise

An unwrap that fails inside the 24-hour window means someone else spent the token. This is the
detection the wrapping is there for, and it is not a hiccup to retry.

Re-run the script with `--reissue`, which revokes the token the attacker holds and mints another, and
find out who read the channel. The mint time in the Lambda's logs is what separates a genuine
compromise from an expired wrap: an unwrap attempted after the TTL fails for the ordinary reason and
costs only another mint.

## If minting fails partway

The script's errors say what state was left behind and name any accessor that needs revoking by
hand. An error naming an accessor is the one case that needs a follow-up: revoke it with
`bao token revoke -accessor <accessor>` before minting again.
