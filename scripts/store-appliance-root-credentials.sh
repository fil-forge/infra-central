#!/usr/bin/env bash
# Store a second copy of an appliance OpenBao's root token and recovery key in
# central's OpenBao. The first copy is in 1Password.
#
# Run it right after provision-platform.sh prints the two values on the node, and
# again whenever either changes: a rebuilt node prints new ones, and so does
# `bao operator generate-root`.
#
# The values are typed at a prompt that does not echo. They reach the provision
# Lambda in a payload file only this user can read, which is deleted on exit, so
# neither appears on a command line, in the shell history or in a log.
#
# Two invocations, always in this order:
#   1. without confirmation, which reports whether central already holds a copy
#   2. after you approve it, with confirmation, which stores both values
#
# Reading them back is break-glass and has no script. See "Reading them back"
# in docs/appliance-onboarding.md.
#
# Usage:
#   scripts/store-appliance-root-credentials.sh --region us-east-9
#
# Options:
#   --region   appliance region label                    (required)
#   --stage    stage the region belongs to               (default: dev)
#
# Prerequisites:
#   - AWS credentials for the account holding the stage
#   - the region's label committed to appliance_regions and merged
set -euo pipefail

STAGE="${STAGE:-dev}"
REGION=""

while [ $# -gt 0 ]; do
  case "$1" in
    --region)  REGION="$2"; shift 2 ;;
    --stage)   STAGE="$2"; shift 2 ;;
    -h|--help) sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

# The payload file holds both values between the prompt and the invocation. bash
# runs no EXIT trap when an untrapped signal kills it, so the signal handler
# exits, which runs the EXIT trap.
PAYLOAD="$(umask 077; mktemp)"
RESPONSE="$(umask 077; mktemp)"
trap 'rm -f "$PAYLOAD" "$RESPONSE"' EXIT
trap 'exit 130' INT TERM HUP

# invoke — send $PAYLOAD to the phase and print its JSON response. A Lambda error
# is reported as a successful invocation with FunctionError set, so that is
# checked separately.
#
# The payload is passed as a file, never as an argument: an argument is visible
# to every process on the machine for as long as the call runs.
#
# Every failure has to become an explicit return: bash drops errexit inside
# command substitution, and the callers read this function through one.
invoke() {
  local response
  if ! response="$(aws lambda invoke \
    --function-name "$FUNCTION" \
    --payload "fileb://$PAYLOAD" \
    --cli-read-timeout 900 \
    "$RESPONSE")"; then
    echo "ERROR: aws lambda invoke failed" >&2
    return 1
  fi

  if [ "$(jq -r '.FunctionError // empty' <<<"$response")" != "" ]; then
    echo "ERROR: the appliance-root-store phase failed:" >&2
    jq -r '.errorMessage // .' "$RESPONSE" >&2
    return 1
  fi

  cat "$RESPONSE"
}

echo "=== Store the ${REGION} appliance's root credentials in ${STAGE} ==="
echo "  Lambda: $FUNCTION"
echo

echo "Reading central's OpenBao (nothing is stored yet)…"
jq -nc --arg region "$REGION" '{phase:"appliance-root-store", region:$region}' >"$PAYLOAD"
plan="$(invoke)"

jq -r '
  .root_credentials_plan as $p |
  if $p.action == "replace" then
    "Central holds version \($p.stored_version) for \($p.region). Storing replaces it; the old version stays readable."
  else
    "Central holds no copy for \($p.region)."
  end
' <<<"$plan"
echo

echo "Paste the two values provision-platform.sh printed. Neither is echoed."
read -rsp "root token: " root_token; echo
read -rsp "recovery key: " recovery_key; echo
if [ -z "$root_token" ] || [ -z "$recovery_key" ]; then
  echo "ERROR: both values are required; nothing was stored" >&2
  exit 1
fi
echo

read -r -p "Type 'store' to proceed: " reply
[ "$reply" = "store" ] || { echo "Aborted; nothing was stored."; exit 1; }
echo

# printf is a shell builtin, so the values reach jq on its stdin and never as an
# argument of any process.
printf '%s\n%s\n' "$root_token" "$recovery_key" | jq -Rnc --arg region "$REGION" \
  '{phase:"appliance-root-store", confirm:true, region:$region, root_token:input, recovery_key:input}' \
  >"$PAYLOAD"
unset root_token recovery_key

result="$(invoke)"
: >"$PAYLOAD"

jq -r '.root_credentials_result | "  ✓ stored \(.region) as version \(.version)"' <<<"$result"
echo
echo "Keep the 1Password entry too. Central's copy is the second one, not the only one."
