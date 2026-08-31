#!/usr/bin/env bash
# Wait for every ECS service in a cluster to reach steady state, and name the
# ones that do not.
#
# `aws ecs wait services-stable` waits on the same condition and reports
# "Max attempts exceeded" and nothing else, so a deploy that hangs leaves the
# run without the fact that explains it: which service is short of its desired
# count, and what ECS says about it. This polls the same condition, prints the
# services still short of it while it waits, and prints their ECS events before
# it gives up.
#
# Steady state is one deployment with as many tasks running as desired, which is
# what the waiter checks too.
#
# Usage:
#   scripts/wait-services-stable.sh <cluster> [--timeout 600] [--interval 15]
#
# Options:
#   --timeout   seconds to wait before failing   (default: 600)
#   --interval  seconds between polls            (default: 15)
#
# Prerequisites:
#   - AWS credentials for the account holding the cluster
set -euo pipefail

TIMEOUT="${TIMEOUT:-600}"
INTERVAL="${INTERVAL:-15}"
CLUSTER=""

if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then
  CLUSTER="$1"; shift
fi

# Without this, `set -u` turns a trailing `--timeout` into an "unbound variable"
# abort, which says nothing about what the caller got wrong.
require_value() {
  [ $# -ge 2 ] || { echo "ERROR: $1 requires a value" >&2; exit 2; }
}

while [ $# -gt 0 ]; do
  case "$1" in
    --timeout)  require_value "$@"; TIMEOUT="$2"; shift 2 ;;
    --interval) require_value "$@"; INTERVAL="$2"; shift 2 ;;
    -h|--help)  sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[ -n "$CLUSTER" ] || { echo "ERROR: cluster name or ARN required" >&2; exit 2; }
command -v aws >/dev/null || { echo "ERROR: aws CLI not found in PATH" >&2; exit 1; }

# DescribeServices takes at most ten services per call, so the cluster's
# services are polled in batches of ten.
BATCH=10

services=()
while IFS= read -r arn; do
  services+=("$arn")
done < <(
  aws ecs list-services --cluster "$CLUSTER" --query 'serviceArns[]' --output text \
    | tr '\t' '\n' | sed -e '/^None$/d' -e '/^$/d'
)

if [ "${#services[@]}" -eq 0 ]; then
  echo "no services in cluster ${CLUSTER}, nothing to wait for"
  exit 0
fi

echo "waiting up to ${TIMEOUT}s for ${#services[@]} service(s) to reach steady state"

# One line per service short of steady state: name, desired, running,
# deployments, rollout state. A service ECS cannot describe at all is reported
# too, with the reason it gives, so a deleted service does not read as a
# service that never stabilises.
describe_unstable() {
  # shellcheck disable=SC2016 # the backticks are JMESPath literals
  aws ecs describe-services --cluster "$CLUSTER" --services "$@" \
    --query 'services[?length(deployments)!=`1` || runningCount!=desiredCount].[serviceName,desiredCount,runningCount,length(deployments),deployments[0].rolloutState]' \
    --output text
  aws ecs describe-services --cluster "$CLUSTER" --services "$@" \
    --query 'failures[].[arn,reason]' --output text
}

unstable_services() {
  local index
  for ((index = 0; index < ${#services[@]}; index += BATCH)); do
    describe_unstable "${services[@]:index:BATCH}"
  done
}

deadline=$((SECONDS + TIMEOUT))
while :; do
  waiting="$(unstable_services)"
  if [ -z "$waiting" ]; then
    echo "every service reached steady state after ${SECONDS}s"
    exit 0
  fi

  echo "after ${SECONDS}s, still waiting on:"
  printf '%s\n' "$waiting" | sed 's/^/  /'

  [ "$SECONDS" -lt "$deadline" ] || break
  sleep "$INTERVAL"
done

echo "ERROR: not every service reached steady state within ${TIMEOUT}s" >&2

# The service's own account of what it tried, which is where a task that cannot
# start says so: no capacity, an image it cannot pull, a health check it keeps
# failing.
while IFS=$'\t' read -r name _; do
  [ -n "$name" ] || continue
  echo >&2
  echo "--- recent ECS events for ${name} ---" >&2
  aws ecs describe-services --cluster "$CLUSTER" --services "$name" \
    --query 'services[].events[:10].[createdAt,message]' --output text >&2
done <<<"$waiting"

exit 1
