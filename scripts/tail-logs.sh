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

# Without this, `set -u` turns a trailing `--lines` into an "unbound variable"
# abort, which says nothing about what the caller got wrong.
require_value() {
  [ $# -ge 2 ] || { echo "ERROR: $1 requires a value" >&2; exit 2; }
}

while [ $# -gt 0 ]; do
  case "$1" in
    --lines)   require_value "$@"; LINES="$2"; shift 2 ;;
    --since)   require_value "$@"; SINCE="$2"; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

command -v aws >/dev/null || { echo "ERROR: aws CLI not found in PATH" >&2; exit 1; }

list_groups() {
  local prefix="$1"
  # A query matching nothing prints a literal `None`, which would otherwise be
  # tailed as if it were a log group.
  aws logs describe-log-groups \
    --log-group-name-prefix "$prefix" \
    --query 'logGroups[].logGroupName' \
    --output text | tr '\t' '\n' | sed -e '/^None$/d' -e '/^$/d' | sort
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

errors="$(mktemp)"
trap 'rm -f "$errors"' EXIT

while IFS= read -r group; do
  echo
  echo "--- ${group} ---"
  echo "aws logs tail '$group' --since '$SINCE' --format short"
  # tail exits non-zero when the group has no events in the window, which is
  # not a failure worth aborting the whole sweep for. Anything it writes to
  # stderr is reported below instead, so an AccessDenied or a wrong region does
  # not read as an empty log group.
  lines="$(aws logs tail "$group" --since "$SINCE" --format short 2>"$errors" | tail -n "$LINES" || true)"
  if [ -n "$lines" ]; then
    printf '%s\n' "$lines"
  elif [ ! -s "$errors" ]; then
    echo "  (no events in the last ${SINCE})"
  fi
  if [ -s "$errors" ]; then
    sed 's/^/  /' "$errors" >&2
  fi
done <<<"$groups"
