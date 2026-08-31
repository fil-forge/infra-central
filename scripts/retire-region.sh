#!/usr/bin/env bash
# Remove a region's Ingot identity from hilt and from SSM, so the region can be
# onboarded again under a different DID.
#
# Run it when the derived Ingot DID changes. Nothing else heals: hilt's provider
# row is keyed by the DID and hilt ships no command to move one, and the
# delegation hilt signed is stored under a name that does not mention the
# audience, so an onboard re-run returns the old proof and logs "returning the
# delegation issued earlier". Deleting the stored delegation is what makes the
# next onboard reissue it.
#
# It does not touch sprue, the delegator or the node's unseal credential. Piri's
# identity is unaffected, and the node's accessor stays where the vault phase
# expects it.
#
# The deletes are made by the provision Lambda, in AWS, because hilt's database is
# private to the VPC and its DSN lives in SSM.
#
# Two invocations, always in this order:
#   1. without confirmation, which reads hilt and SSM and prints what it found
#   2. after you approve it, with confirmation, which deletes
#
# Usage:
#   scripts/retire-region.sh --region us-east-9
#
# Options:
#   --region   appliance region label                    (required)
#   --stage    stage to retire the region in             (default: dev)
#   --yes      skip the interactive prompt
#
# Afterwards, re-onboard with scripts/onboard-appliance.sh. The log line has to be
# "issued hilt's S3 delegation to the appliance" with the new audience.
#
# Prerequisites:
#   - AWS credentials for the account holding the stage
set -euo pipefail

STAGE="${STAGE:-dev}"
REGION=""
ASSUME_YES=false

while [ $# -gt 0 ]; do
  case "$1" in
    --region)  REGION="$2"; shift 2 ;;
    --stage)   STAGE="$2"; shift 2 ;;
    --yes|-y)  ASSUME_YES=true; shift ;;
    -h|--help) sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$REGION" ]; then
  echo "ERROR: --region is required" >&2
  exit 2
fi

command -v aws >/dev/null || { echo "ERROR: aws CLI not found in PATH" >&2; exit 1; }
command -v jq  >/dev/null || { echo "ERROR: jq not found in PATH" >&2; exit 1; }

FUNCTION="fc-${STAGE}-provision"

# invoke <confirm> — call the retire phase and print its JSON response. A Lambda
# error is reported as a successful invocation with FunctionError set, so that is
# checked separately.
invoke() {
  local confirm="$1" payload response out
  payload="$(jq -nc \
    --argjson confirm "$confirm" \
    --arg region "$REGION" \
    '{phase:"retire", confirm:$confirm, region:$region}')"

  out="$(mktemp)"
  trap 'rm -f "$out"' RETURN

  response="$(aws lambda invoke \
    --function-name "$FUNCTION" \
    --cli-binary-format raw-in-base64-out \
    --payload "$payload" \
    --cli-read-timeout 900 \
    "$out")"

  if [ "$(jq -r '.FunctionError // empty' <<<"$response")" != "" ]; then
    echo "ERROR: the retire phase failed:" >&2
    jq -r '.errorMessage // .' "$out" >&2
    return 1
  fi

  cat "$out"
}

echo "=== Retire the ${REGION} Ingot identity in ${STAGE} ==="
echo "  Lambda: $FUNCTION"
echo

echo "Reading hilt and SSM (nothing is deleted yet)…"
plan="$(invoke false)"

jq -r '
  .retire_plan as $p |
  "Found:",
  "  hilt provider:   \(if ($p.provider_did // "") == "" then "no row for this region" else $p.provider_did end)",
  (if ($p.rows // {}) == {} then
     empty
   else
     "  hilt rows:", ($p.rows | to_entries[] | "    \(.key): \(.value)")
   end),
  (if (($p.parameters // []) | length) == 0 then
     "  stored delegation: absent"
   else
     "  stored delegation:", ($p.parameters[] | "    \(.)")
   end)
' <<<"$plan"
echo

nothing="$(jq -r '
  (((.retire_plan.provider_did // "") == "")
   and (((.retire_plan.parameters // []) | length) == 0))' <<<"$plan")"
if [ "$nothing" = "true" ]; then
  echo "Nothing to retire. The region holds no provider row and no stored delegation."
  exit 0
fi

echo "Deleting these is permanent. Every tenant, bucket and access key under that"
echo "provider goes with it, and the node's copy of the delegation has to be"
echo "replaced with the one the next onboard issues."
echo

if [ "$ASSUME_YES" != true ]; then
  read -r -p "Type 'retire' to proceed: " reply
  [ "$reply" = "retire" ] || { echo "Aborted; nothing was deleted."; exit 1; }
  echo
fi

result="$(invoke true)"

jq -r '
  .retire_result as $r |
  (if ($r.rows // {}) == {} then
     "  ✓ hilt held no rows for the region"
   else
     ($r.rows | to_entries[] | "  ✓ deleted \(.value) \(.key) row(s)")
   end),
  (if (($r.parameters // []) | length) == 0 then
     "  ✓ no stored delegation to delete"
   else
     ($r.parameters[] | "  ✓ deleted \(.)")
   end)
' <<<"$result"
echo

echo "Now re-onboard with scripts/onboard-appliance.sh. Its log line has to be"
echo "\"issued hilt's S3 delegation to the appliance\" with the new audience;"
echo "\"returning the delegation issued earlier\" means this did not take effect."
