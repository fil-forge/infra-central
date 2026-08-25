#!/usr/bin/env bash
# Register a regional appliance with Central services, and return the delegation
# its Ingot needs.
#
# Four things happen, none of which an apply can do. The appliance's Piri DID
# goes on the delegator's allow list, without which `piri init` is refused with a
# 403. Its Piri is registered with sprue and given a weight, without which
# uploads fail with CandidateUnavailable. Its Ingot is registered with hilt for
# its region, without which hilt rejects every tenant there. And hilt signs the
# S3 delegation its Ingot presents, which only Central can issue.
#
# The writes are made by the provision Lambda, in AWS, because sprue and hilt
# accept an admin call only when it is signed by their own identity key. Those
# keys stay in SSM and never reach a laptop.
#
# Two invocations, always in this order:
#   1. without confirmation, which reads all three services and prints what it
#      would change
#   2. after you approve it, with confirmation, which performs the writes
#
# Run it after the appliance has provisioned its keys, so its DIDs exist.
#
# Usage:
#   scripts/onboard-appliance.sh \
#     --region us-east-9 \
#     --piri-did did:key:z6Mk... \
#     --ingot-did did:key:z6Mk... \
#     --piri-url https://piri.dev.forge-sandbox.fil.one \
#     --piri-proof-file piri-proof.txt
#
# Options:
#   --region            appliance region label                    (required)
#   --piri-did          the appliance's Piri did:key              (required)
#   --ingot-did         the appliance's Ingot did:key             (required)
#   --piri-url          where Piri answers publicly              (required)
#   --piri-proof-file   the proof the appliance signed for sprue (required
#                       unless sprue already has the provider)
#   --proof-out         write the returned delegation here   (default: stdout)
#   --stage             stage to register with                    (default: dev)
#   --weight            sprue scheduling weight                   (default: 100)
#   --replication-weight  sprue replication weight                (default: 100)
#   --yes               skip the interactive prompt
#
# Prerequisites:
#   - AWS credentials for the account holding the stage
#   - the appliance provisioned, so its two DIDs exist
set -euo pipefail

STAGE="${STAGE:-dev}"
REGION=""
PIRI_DID=""
INGOT_DID=""
PIRI_URL=""
PROOF_FILE=""
PROOF_OUT=""
WEIGHT=""
REPLICATION_WEIGHT=""
ASSUME_YES=false

while [ $# -gt 0 ]; do
  case "$1" in
    --region)             REGION="$2"; shift 2 ;;
    --piri-did)           PIRI_DID="$2"; shift 2 ;;
    --ingot-did)          INGOT_DID="$2"; shift 2 ;;
    --piri-url)           PIRI_URL="$2"; shift 2 ;;
    --piri-proof-file)    PROOF_FILE="$2"; shift 2 ;;
    --proof-out)          PROOF_OUT="$2"; shift 2 ;;
    --stage)              STAGE="$2"; shift 2 ;;
    --weight)             WEIGHT="$2"; shift 2 ;;
    --replication-weight) REPLICATION_WEIGHT="$2"; shift 2 ;;
    --yes|-y)             ASSUME_YES=true; shift ;;
    -h|--help)            sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)                    echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

for required in REGION PIRI_DID INGOT_DID PIRI_URL; do
  if [ -z "${!required}" ]; then
    echo "ERROR: --$(echo "$required" | tr 'A-Z_' 'a-z-') is required" >&2
    exit 2
  fi
done

command -v aws >/dev/null || { echo "ERROR: aws CLI not found in PATH" >&2; exit 1; }
command -v jq  >/dev/null || { echo "ERROR: jq not found in PATH" >&2; exit 1; }

# The proof is sent base64-encoded, whatever form the file holds. A bare
# DAG-CBOR container is binary and carries NUL bytes, which neither a shell
# variable nor a JSON string can hold, so reading such a file as text would
# corrupt it before it left the laptop. Encoding both forms means nothing here
# has to guess which one the appliance sent.
PIRI_PROOF_B64=""
if [ -n "$PROOF_FILE" ]; then
  [ -r "$PROOF_FILE" ] || { echo "ERROR: cannot read $PROOF_FILE" >&2; exit 1; }
  PIRI_PROOF_B64="$(base64 < "$PROOF_FILE" | tr -d '\n')"
fi

FUNCTION="fc-${STAGE}-provision"

# invoke <confirm> — call the onboard phase and print its JSON response. A Lambda
# error is reported as a successful invocation with FunctionError set, so that is
# checked separately.
invoke() {
  local confirm="$1" payload response out
  payload="$(jq -nc \
    --argjson confirm "$confirm" \
    --arg region "$REGION" \
    --arg piri "$PIRI_DID" \
    --arg ingot "$INGOT_DID" \
    --arg url "$PIRI_URL" \
    --arg proof "$PIRI_PROOF_B64" \
    --arg weight "$WEIGHT" \
    --arg replication "$REPLICATION_WEIGHT" \
    '{phase:"onboard", confirm:$confirm, region:$region, piri_did:$piri,
      ingot_did:$ingot, piri_url:$url}
     + (if $proof       == "" then {} else {piri_proof_b64:$proof} end)
     + (if $weight      == "" then {} else {weight:($weight|tonumber)} end)
     + (if $replication == "" then {} else {replication_weight:($replication|tonumber)} end)')"

  out="$(mktemp)"
  trap 'rm -f "$out"' RETURN

  response="$(aws lambda invoke \
    --function-name "$FUNCTION" \
    --cli-binary-format raw-in-base64-out \
    --payload "$payload" \
    --cli-read-timeout 900 \
    "$out")"

  if [ "$(jq -r '.FunctionError // empty' <<<"$response")" != "" ]; then
    echo "ERROR: the onboard phase failed:" >&2
    jq -r '.errorMessage // .' "$out" >&2
    return 1
  fi

  cat "$out"
}

echo "=== Onboard the ${REGION} appliance with ${STAGE} ==="
echo "  Lambda: $FUNCTION"
echo "  Piri:   $PIRI_DID at $PIRI_URL"
echo "  Ingot:  $INGOT_DID"
echo

echo "Reading sprue, hilt and the delegator (nothing is written yet)…"
plan="$(invoke false)"

jq -r '
  .onboard_plan as $p |
  "Current state:",
  "  Delegator allow list:  \(if $p.allow_listed then "listed" else "absent" end)",
  (if $p.sprue == null then
     "  sprue provider:        absent"
   else
     "  sprue provider:        \($p.sprue.endpoint), weights \($p.sprue.weight)/\($p.sprue.replication_weight)"
   end),
  "  hilt region:           \(if $p.hilt_region == "" then "absent" else $p.hilt_region end)",
  "",
  (if (($p.blockers // []) | length) > 0 then
     empty
   elif ($p.actions | length) == 0 then
     "Already registered. The run would return the existing delegation and change nothing else."
   else
     "Writes to perform:", ($p.actions[] | "  - \(.)")
   end)
' <<<"$plan"

blockers="$(jq -r '.onboard_plan.blockers // [] | length' <<<"$plan")"
if [ "$blockers" != "0" ]; then
  echo "Cannot proceed:" >&2
  jq -r '.onboard_plan.blockers[] | "  - \(.)"' <<<"$plan" >&2
  echo >&2
  echo "Each of these would have to destroy something to resolve, so nothing is" >&2
  echo "written. Decide what the right state is and correct it deliberately." >&2
  exit 1
fi

if [ "$ASSUME_YES" != true ]; then
  read -r -p "Type 'onboard' to proceed: " reply
  [ "$reply" = "onboard" ] || { echo "Aborted; nothing was written."; exit 1; }
  echo
fi

result="$(invoke true)"

jq -r '.onboard_result.performed[] | "  ✓ \(.)"' <<<"$result"
echo

proof="$(jq -r '.onboard_result.hilt_ingot_s3_proof' <<<"$result")"

if [ -n "$PROOF_OUT" ]; then
  printf '%s' "$proof" > "$PROOF_OUT"
  echo "Wrote hilt's S3 delegation to $PROOF_OUT."
else
  echo "hilt's S3 delegation for this appliance's Ingot:"
  echo
  printf '%s\n' "$proof"
  echo
fi

echo "Give it to the appliance as the proof its Ingot presents to hilt. It is not"
echo "a secret: a delegation is useless without the audience's own key. It is also"
echo "issued once and stored, so re-running this returns the same bytes."
