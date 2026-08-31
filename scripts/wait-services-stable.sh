#!/usr/bin/env bash
# Wait until every ECS service in a cluster has finished rolling out, and say
# which ones have not when the wait runs out.
#
# `aws ecs wait services-stable` does the same job in one call, with two
# problems this replaces. Its budget is forty attempts fifteen seconds apart and
# nothing changes it, and ten minutes is short: the first deploy that attaches a
# load balancer to a service has to start a task, wait out its health check
# grace period, and pass two ALB checks thirty seconds apart before the old task
# drains. Its failure also names no service, so a run that times out says only
# that something in the cluster was still moving.
#
# A service is done when it has one deployment left and the tasks it wants are
# running, which is what the waiter checks too.
#
# Usage:
#   scripts/wait-services-stable.sh <cluster> [--timeout 1200] [--interval 15]
#
# Options:
#   --timeout   seconds to wait before giving up   (default: 1200)
#   --interval  seconds between polls              (default: 15)
#
# Prerequisites:
#   - AWS credentials for the account holding the cluster
#   - aws and jq
set -euo pipefail

CLUSTER=""
TIMEOUT="${TIMEOUT:-1200}"
INTERVAL="${INTERVAL:-15}"

require_value() {
  [ $# -ge 2 ] || { echo "ERROR: $1 requires a value" >&2; exit 2; }
}

while [ $# -gt 0 ]; do
  case "$1" in
    --timeout)  require_value "$@"; TIMEOUT="$2"; shift 2 ;;
    --interval) require_value "$@"; INTERVAL="$2"; shift 2 ;;
    -h|--help)  sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)         echo "unknown option: $1" >&2; exit 2 ;;
    *)
      [ -z "$CLUSTER" ] || { echo "ERROR: unexpected argument: $1" >&2; exit 2; }
      CLUSTER="$1"; shift ;;
  esac
done

[ -n "$CLUSTER" ] || { echo "usage: scripts/wait-services-stable.sh <cluster>" >&2; exit 2; }

command -v aws >/dev/null || { echo "ERROR: aws CLI not found in PATH" >&2; exit 1; }
command -v jq  >/dev/null || { echo "ERROR: jq not found in PATH" >&2; exit 1; }

# describe-services takes ten at a time, so the service list is walked in tens
# wherever it is read.
BATCH=10

services="$(
  aws ecs list-services --cluster "$CLUSTER" --query 'serviceArns[]' --output text \
    | tr '\t' '\n' | sed -e '/^None$/d' -e '/^$/d' | sort
)"

if [ -z "$services" ]; then
  echo "ERROR: no services in cluster '$CLUSTER'" >&2
  echo "The apply ran, so a cluster with nothing in it means the wait would verify nothing." >&2
  exit 1
fi

# Read into an array rather than with mapfile, which macOS's bash 3.2 does not
# have and every other script here manages without.
SERVICES=()
while IFS= read -r service; do SERVICES+=("$service"); done <<<"$services"
count="${#SERVICES[@]}"
echo "=== Waiting up to ${TIMEOUT}s for ${count} service(s) to reach steady state ==="

# describe <jq filter> <service...> — one describe-services call per ten
# services, with the filter applied to each response.
#
# With more than ten services a batch that fails while a later one succeeds
# returns 0, and its error text is printed as if it were a pending service name.
# The next poll corrects it; the cluster holds seven services today.
describe() {
  local filter="$1"; shift
  local batch
  while [ $# -gt 0 ]; do
    batch=$(($# < BATCH ? $# : BATCH))
    aws ecs describe-services \
      --cluster "$CLUSTER" \
      --services "${@:1:batch}" \
      --output json \
      | jq -r "$filter"
    shift "$batch"
  done
}

# A service the describe call cannot return counts as pending rather than
# stable, so an ARN that disappeared between the list and the describe is
# reported at the deadline instead of passing silently.
PENDING_NAMES='
  (.services[]
   | select((.deployments | length) != 1 or .runningCount != .desiredCount)
   | .serviceName),
  (.failures[]? | "\(.arn) (\(.reason))")
'

# The name, what it is waiting for, and the reason ECS gives, for everything
# still moving when the wait runs out. rolloutStateReason is where a task that
# keeps failing its health check shows up.
#
# AWS CLI v2 returns createdAt as an ISO-8601 string and v1 as epoch seconds,
# and jq aborts the whole filter on the wrong type, which would drop the events
# and everything after them exactly when a service times out.
PENDING_DETAIL='
  def fmtdate: if type == "number" then floor | todate else . end;
  (.services[]
  | select((.deployments | length) != 1 or .runningCount != .desiredCount)
  | "--- \(.serviceName) ---",
    "  running \(.runningCount)/\(.desiredCount), \(.deployments | length) deployment(s)",
    (.deployments[] | "  \(.status) \(.rolloutState // "-"): \(.rolloutStateReason // "-")"),
    "  recent events:",
    (.events[:10][] | "    \(.createdAt | fmtdate) \(.message)")),
  (.failures[]? | "--- \(.arn) ---", "  describe-services: \(.reason)")
'

started="$SECONDS"
last_report=""
last_heartbeat=0

while true; do
  # A describe call that fails is a reason to poll again, not to fail the
  # deploy: only the deadline below ends this loop unhappily. Without the
  # guard a single throttled call would report every service as pending.
  if ! pending="$(describe "$PENDING_NAMES" "${SERVICES[@]}" 2>&1)"; then
    echo "  (describe-services failed, retrying: $(printf '%s' "$pending" | tail -n 1))"
    pending="?"
  elif [ -z "$pending" ]; then
    echo "All ${count} service(s) reached steady state after $((SECONDS - started))s."
    exit 0
  fi

  elapsed=$((SECONDS - started))

  # Every change, and a heartbeat once a minute otherwise. Polling every fifteen
  # seconds for twenty minutes would otherwise print eighty identical lines.
  if [ "$pending" != "$last_report" ] || [ $((elapsed - last_heartbeat)) -ge 60 ]; then
    printf '  [%4ds] waiting on: %s\n' "$elapsed" "$(printf '%s' "$pending" | tr '\n' ' ')"
    last_report="$pending"
    last_heartbeat="$elapsed"
  fi

  if [ "$elapsed" -ge "$TIMEOUT" ]; then
    echo
    echo "ERROR: still not stable after ${elapsed}s:" >&2
    describe "$PENDING_DETAIL" "${SERVICES[@]}" >&2 || true
    exit 1
  fi

  sleep "$INTERVAL"
done
