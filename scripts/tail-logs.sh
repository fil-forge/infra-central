#!/usr/bin/env bash
# Print the tail of every log group a stage owns: the ECS services from both the
# platform and apps workspaces, plus the provision Lambda.
#
# The groups are discovered from CloudWatch rather than listed here, so a new
# service shows up without editing this script. Everything a stage writes lands
# under /forge-central/<stage>/, except the Lambda, which AWS names for us.
#
# Usage:
#   scripts/tail-logs.sh [stage] [--lines 10] [--since 1h]
#
# Options:
#   --lines   log lines to print per service   (default: 10)
#   --since   how far back to look, as accepted by `aws logs tail`
#             (default: 1h; also takes 30m, 2d, or a timestamp)
#
# Prerequisites:
#   - AWS credentials for the account holding the stage
set -euo pipefail

STAGE="${STAGE:-dev}"
LINES="${LINES:-10}"
SINCE="${SINCE:-1h}"

if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then
  STAGE="$1"; shift
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --lines)   LINES="$2"; shift 2 ;;
    --since)   SINCE="$2"; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

command -v aws >/dev/null || { echo "ERROR: aws CLI not found in PATH" >&2; exit 1; }

list_groups() {
  local prefix="$1"
  aws logs describe-log-groups \
    --log-group-name-prefix "$prefix" \
    --query 'logGroups[].logGroupName' \
    --output text | tr '\t' '\n' | sed '/^$/d' | sort
}

groups="$(list_groups "/forge-central/${STAGE}/")"
lambda_groups="$(list_groups "/aws/lambda/fc-${STAGE}-")"
groups="$(printf '%s\n%s\n' "$groups" "$lambda_groups" | sed '/^$/d')"

if [ -z "$groups" ]; then
  echo "ERROR: no log groups found for stage '${STAGE}'" >&2
  echo "Check the stage name and that your AWS credentials point at its account." >&2
  exit 1
fi

echo "=== Logs for the ${STAGE} stage (last ${LINES} lines per service, since ${SINCE}) ==="

while IFS= read -r group; do
  echo
  echo "--- ${group} ---"
  # tail exits non-zero when the group has no events in the window, which is
  # not a failure worth aborting the whole sweep for.
  lines="$(aws logs tail "$group" --since "$SINCE" --format short 2>/dev/null | tail -n "$LINES" || true)"
  if [ -z "$lines" ]; then
    echo "  (no events in the last ${SINCE})"
  else
    printf '%s\n' "$lines"
  fi
done <<<"$groups"
