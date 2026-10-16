#!/usr/bin/env bash
# Remove one Piri from everything central and the delegator hold for it: hilt's
# storage node set for its region, sprue's provider row, the delegator's allow
# list and provider info, and central's record of the region's Piris.
#
# Run it to move a Piri to a new URL, which onboarding refuses to do for a
# registered Piri: remove it here, then onboard it again with
# scripts/onboard-appliance.sh and its proof. Run it as well to evict a Piri for
# good.
#
# It leaves the Piri's on-chain provider and data sets alone. They belong to the
# Piri's own wallet, which central does not hold.
#
# The writes are made by the provision Lambda, in AWS, because sprue and hilt
# accept admin invocations only when signed with their own keys, which live in
# Secrets Manager.
#
# Two invocations, always in this order:
#   1. without confirmation, which reads every registry and prints what it found
#   2. after you approve it, with confirmation, which removes
#
# Usage:
#   scripts/remove-piri.sh --region us-east-9 --piri-did did:key:z6Mk...
#
# Options:
#   --region     region the Piri belongs to             (required)
#   --piri-did   the Piri's did:key                      (required)
#   --stage      stage to remove it from                 (default: dev)
#   --yes        skip the interactive prompt
#
# A Piri hilt routes its region to alone cannot be removed, because hilt refuses
# an empty storage node set. Onboard another Piri first, or delete hilt's row
# with scripts/retire-region.sh when the whole node is leaving.
#
# Prerequisites:
#   - AWS credentials for the account holding the stage
set -euo pipefail

STAGE="${STAGE:-dev}"
REGION=""
PIRI_DID=""
ASSUME_YES=false

while [ $# -gt 0 ]; do
  case "$1" in
    --region)   REGION="$2"; shift 2 ;;
    --piri-did) PIRI_DID="$2"; shift 2 ;;
    --stage)    STAGE="$2"; shift 2 ;;
    --yes|-y)   ASSUME_YES=true; shift ;;
    -h|--help)  sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

for required in REGION PIRI_DID; do
  if [ -z "${!required}" ]; then
    flag="--$(tr '[:upper:]_' '[:lower:]-' <<<"$required")"
    echo "ERROR: $flag is required" >&2
    exit 2
  fi
done

command -v aws >/dev/null || { echo "ERROR: aws CLI not found in PATH" >&2; exit 1; }
command -v jq  >/dev/null || { echo "ERROR: jq not found in PATH" >&2; exit 1; }

FUNCTION="fc-${STAGE}-provision"

# invoke <confirm> — call the remove-piri phase and print its JSON response. A
# Lambda error is reported as a successful invocation with FunctionError set, so
# that is checked separately.
#
# Every failure has to become an explicit return: bash drops errexit inside
# command substitution, and the callers read this function through one.
invoke() {
  local confirm="$1" payload response out
  payload="$(jq -nc \
    --argjson confirm "$confirm" \
    --arg region "$REGION" \
    --arg piri_did "$PIRI_DID" \
    '{phase:"remove-piri", confirm:$confirm, region:$region, piri_did:$piri_did}')"

  out="$(mktemp)" || return 1
  trap 'rm -f "$out"' RETURN

  if ! response="$(aws lambda invoke \
    --function-name "$FUNCTION" \
    --cli-binary-format raw-in-base64-out \
    --payload "$payload" \
    --cli-read-timeout 900 \
    "$out")"; then
    echo "ERROR: aws lambda invoke failed" >&2
    return 1
  fi

  if [ "$(jq -r '.FunctionError // empty' <<<"$response")" != "" ]; then
    echo "ERROR: the remove-piri phase failed:" >&2
    jq -r '.errorMessage // .' "$out" >&2
    return 1
  fi

  cat "$out"
}

echo "=== Remove Piri ${PIRI_DID} from ${REGION} in ${STAGE} ==="
echo "  Lambda: $FUNCTION"
echo

echo "Reading sprue, hilt, the delegator and the region record (nothing is removed yet)…"
plan="$(invoke false)"

jq -r '
  .remove_piri_plan as $p |
  def present(f): if f then "present" else "absent" end;
  "Current state:",
  "  recorded under:        \(if (($p.recorded_regions // []) | length) == 0 then "none" else ($p.recorded_regions | join(", ")) end)",
  "  Piris in the region:   \(if (($p.recorded_piris // []) | length) == 0 then "none" else ($p.recorded_piris | join(", ")) end)",
  "  hilt routing policy:   \(if $p.hilt_policy == "" then "none" else $p.hilt_policy end)",
  (if $p.sprue == null then
     "  sprue provider:        absent"
   else
     "  sprue provider:        \($p.sprue.endpoint), weights \($p.sprue.weight)/\($p.sprue.replication_weight)"
   end),
  "  delegator allow list:  \(present($p.allow_listed))",
  "  delegator provider:    \(present($p.provider_info))",
  "",
  ($p.notes[] | "Note: \(.)"),
  "",
  (if (($p.blockers // []) | length) > 0 then
     empty
   elif (($p.actions // []) | length) == 0 then
     "Nothing holds this Piri. There is nothing to remove."
   else
     "Removals to perform:", ($p.actions[] | "  - \(.)")
   end)
' <<<"$plan"

blockers="$(jq -r '.remove_piri_plan.blockers // [] | length' <<<"$plan")"
if [ "$blockers" != "0" ]; then
  echo "Cannot proceed:" >&2
  jq -r '.remove_piri_plan.blockers[] | "  - \(.)"' <<<"$plan" >&2
  exit 1
fi

if [ "$(jq -r '.remove_piri_plan.actions // [] | length' <<<"$plan")" = "0" ]; then
  exit 0
fi

echo
echo "sprue stops sending this Piri uploads and replicas, and its DID can no longer"
echo "pass the delegator's approval until it is onboarded again."
echo

if [ "$ASSUME_YES" != true ]; then
  read -r -p "Type 'remove' to proceed: " reply
  [ "$reply" = "remove" ] || { echo "Aborted; nothing was removed."; exit 1; }
  echo
fi

result="$(invoke true)"

jq -r '.remove_piri_result.performed[] | "  ✓ \(.)"' <<<"$result"
