#!/usr/bin/env bash
# Check that every identity and wallet key has a replica in the DR region that
# derives the same DID or address as its primary.
#
# The comparison runs inside the provision Lambda, in AWS, so no key leaves it.
# The phase only reads, and returns DIDs and addresses, never a key.
#
# Usage:
#   scripts/check-key-replicas.sh [--stage staging]
#
# Options:
#   --stage  stage to check  (default: dev)
#
# Exits 1 when any key's replica is missing or derives a different DID or
# address. A replica the seed phase added moments ago may still be in progress
# and show as missing; run the check again a minute later.
#
# Prerequisites:
#   - AWS credentials for the account holding the stage
#   - AWS_REGION set to the stage's primary region (the Makefile sets it)
set -euo pipefail

STAGE="${STAGE:-dev}"

while [ $# -gt 0 ]; do
  case "$1" in
    --stage)   STAGE="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

command -v aws >/dev/null || { echo "ERROR: aws CLI not found in PATH" >&2; exit 1; }
command -v jq  >/dev/null || { echo "ERROR: jq not found in PATH" >&2; exit 1; }

FUNCTION="fc-${STAGE}-provision"

out="$(mktemp)"
trap 'rm -f "$out"' EXIT

if ! response="$(aws lambda invoke \
  --function-name "$FUNCTION" \
  --cli-binary-format raw-in-base64-out \
  --payload '{"phase":"check-replicas"}' \
  --cli-read-timeout 900 \
  "$out")"; then
  echo "ERROR: aws lambda invoke failed" >&2
  exit 1
fi

if [ "$(jq -r '.FunctionError // empty' <<<"$response")" != "" ]; then
  echo "ERROR: the check-replicas phase failed:" >&2
  jq -r '.errorMessage // .' "$out" >&2
  exit 1
fi

echo "=== Key replicas of ${STAGE} in $(jq -r '.replica_region' "$out") ==="
jq -r '
  .replica_checks[]
  | if .match then "  ok       \(.key)  \(.primary)"
    elif .replica == null then "  MISSING  \(.key)  primary \(.primary)"
    else "  DIFFERS  \(.key)  primary \(.primary), replica \(.replica)"
    end
' "$out"

if jq -e '[.replica_checks[] | select(.match | not)] | length > 0' "$out" >/dev/null; then
  echo
  echo "Some replicas are missing or differ from their primary." >&2
  exit 1
fi
