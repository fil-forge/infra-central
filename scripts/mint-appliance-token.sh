#!/usr/bin/env bash
# Mint the credential a regional appliance unseals with, and print it once for
# delivery to whoever operates that node.
#
# The minting happens inside the provision Lambda, in AWS. What comes back is not
# the token: it is a single-use wrapping token with a short TTL, which the node
# exchanges for the real one against central OpenBao. So the credential itself
# never transits the channel that carries the hand-off, and an interception makes
# the node's own unwrap fail rather than passing unnoticed. See
# docs/appliance-onboarding.md for the delivery rules, which matter.
#
# Two invocations, always in this order:
#   1. without confirmation, which reads OpenBao and prints what would happen
#   2. after you approve it, with confirmation, which mints
#
# The region's transit key must already exist. It is created by the vault phase
# from appliance_regions in the stage's terraform.tfvars, so a region that has
# not been committed and merged fails here rather than being created on the spot.
#
# Usage:
#   scripts/mint-appliance-token.sh --region us-east-9 --node-ip 203.0.113.7
#
# Options:
#   --region     appliance region label                  (required)
#   --node-ip    the node's Elastic IP, bound as a /32   (required)
#   --node-cidr  bind to this CIDR instead of --node-ip
#   --stage      stage holding the transit key            (default: dev)
#   --period     renewal tolerance                        (default: 72h)
#   --wrap-ttl   how long the hand-off may sit unclaimed  (default: 24h)
#   --reissue    revoke the region's existing token first
#   --yes        skip the interactive prompt
#
# Prerequisites:
#   - AWS credentials for the account holding the stage
#   - the node's Elastic IP already allocated, which is its own apply
set -euo pipefail

STAGE="${STAGE:-dev}"
REGION=""
NODE_IP=""
NODE_CIDR=""
PERIOD=""
WRAP_TTL=""
REISSUE=false
ASSUME_YES=false

while [ $# -gt 0 ]; do
  case "$1" in
    --region)    REGION="$2"; shift 2 ;;
    --node-ip)   NODE_IP="$2"; shift 2 ;;
    --node-cidr) NODE_CIDR="$2"; shift 2 ;;
    --stage)     STAGE="$2"; shift 2 ;;
    --period)    PERIOD="$2"; shift 2 ;;
    --wrap-ttl)  WRAP_TTL="$2"; shift 2 ;;
    --reissue)   REISSUE=true; shift ;;
    --yes|-y)    ASSUME_YES=true; shift ;;
    -h|--help)   sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[ -n "$REGION" ] || { echo "ERROR: --region is required" >&2; exit 2; }

if [ -z "$NODE_CIDR" ]; then
  [ -n "$NODE_IP" ] || { echo "ERROR: --node-ip or --node-cidr is required" >&2; exit 2; }
  NODE_CIDR="${NODE_IP}/32"
fi

command -v aws >/dev/null || { echo "ERROR: aws CLI not found in PATH" >&2; exit 1; }
command -v jq  >/dev/null || { echo "ERROR: jq not found in PATH" >&2; exit 1; }

FUNCTION="fc-${STAGE}-provision"

# The one file the Lambda's response is written to, created with a private umask
# and removed however this script ends. On the confirming call it holds the
# wrapping token, and this is the only place on an operator's disk it ever
# exists. The signals are trapped so an interrupted script still cleans up:
# bash runs no EXIT trap when an untrapped signal kills it, and the file would
# be left holding a live wrapping token for the rest of its 24 hours.
RESPONSE="$(umask 077; mktemp)"
trap 'rm -f "$RESPONSE"' EXIT INT TERM HUP

# invoke <confirm> — call the appliance-token phase and print its JSON response.
# A Lambda error is reported as a successful invocation with FunctionError set,
# so that is checked separately.
invoke() {
  local confirm="$1" payload response
  payload="$(jq -nc \
    --argjson confirm "$confirm" \
    --arg region "$REGION" \
    --arg cidr "$NODE_CIDR" \
    --arg period "$PERIOD" \
    --arg wrap "$WRAP_TTL" \
    --argjson reissue "$REISSUE" \
    '{phase:"appliance-token", confirm:$confirm, region:$region, node_cidr:$cidr,
      reissue:$reissue}
     + (if $period == "" then {} else {period:$period} end)
     + (if $wrap   == "" then {} else {wrap_ttl:$wrap} end)')"

  response="$(aws lambda invoke \
    --function-name "$FUNCTION" \
    --cli-binary-format raw-in-base64-out \
    --payload "$payload" \
    --cli-read-timeout 900 \
    "$RESPONSE")"

  if [ "$(jq -r '.FunctionError // empty' <<<"$response")" != "" ]; then
    echo "ERROR: the appliance-token phase failed:" >&2
    jq -r '.errorMessage // .' "$RESPONSE" >&2
    return 1
  fi

  cat "$RESPONSE"
}

echo "=== Mint the ${REGION} unseal token ==="
echo "  Lambda:  $FUNCTION"
echo "  Region:  $REGION"
echo "  Bound to: $NODE_CIDR"
echo

echo "Reading OpenBao (nothing is minted yet)…"
plan="$(invoke false)"

jq -r '
  "  Transit key:  appliance-unseal-\(.token_plan.region)",
  "  Period:       \(.token_plan.period)",
  "  Wrap TTL:     \(.token_plan.wrap_ttl)",
  "  Action:       \(.token_plan.action)",
  (if .token_plan.accessor == null then empty else
    "  On record:    accessor \(.token_plan.accessor), live: \(.token_plan.token_live)"
  end)
' <<<"$plan"
echo

action="$(jq -r '.token_plan.action' <<<"$plan")"

if [ "$action" = "refuse" ]; then
  echo "This region already has a live unseal token. Two standing credentials for" >&2
  echo "one node is a state nothing can reason about, so this stops here." >&2
  echo >&2
  echo "If the node never received the previous token, or it has leaked, re-run" >&2
  echo "with --reissue, which revokes that token before minting another." >&2
  exit 1
fi

if [ "$ASSUME_YES" != true ]; then
  if [ "$action" = "reissue" ]; then
    echo "The region's current token will be REVOKED. A node still using it stops"
    echo "being able to unseal at its next restart."
  fi
  read -r -p "Type 'mint' to proceed: " reply
  [ "$reply" = "mint" ] || { echo "Aborted; nothing was minted."; exit 1; }
  echo
fi

result="$(invoke true)"

jq -r '
  "Minted. Accessor \(.token_result.accessor) is recorded in SSM;",
  "the token itself is stored nowhere and cannot be printed again.",
  "",
  "Give the node operator this wrapping token:",
  "",
  "    \(.token_result.wrapping_token)",
  "",
  "It can be exchanged once, within \(.token_result.wrap_ttl), and only for this",
  "node'"'"'s credential. Chat is an acceptable channel; a view-once 1Password link",
  "is better. On the node:",
  "",
  "    BAO_ADDR=\(.token_result.unseal_address) bao unwrap <token>",
  "",
  "and write the result to the root-only 0400 file the node reads.",
  "",
  "If that unwrap fails, treat it as a compromise rather than a hiccup: someone",
  "else spent the token. Re-run this script with --reissue and find out who read",
  "the channel."
' <<<"$result"
