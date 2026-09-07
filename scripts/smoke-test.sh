#!/usr/bin/env bash
# Check that a deployed stage's public services answer and publish the identity
# they were given.
#
# Everything is checked over public HTTPS. A 200 from the health path covers the
# whole ingress route at once: the Route53 record, the wildcard certificate, the
# listener rule, the target group and a task passing its container health check.
#
# The did.json check is the one health cannot make. sprue, hilt and swarf mint an
# ephemeral identity when no key is supplied and report themselves healthy either
# way, so a DID matching the hostname is what proves the key arrived from SSM.
#
# OpenBao is covered too. It answers at ssm.<suffix> rather than at its own name,
# because regional appliances authenticate there at boot to unseal.
#
# Usage:
#   scripts/smoke-test.sh <stage>
#
# Example:
#   scripts/smoke-test.sh dev
#
# The hostname suffix comes from terraform/envs/<stage>/platform/terraform.tfvars,
# so the hostnames are the ones the ALB and the certificate were built from.
#
# Prerequisites:
#   - curl and jq
#   - no AWS credentials, and nothing written anywhere
set -euo pipefail

case "${1-}" in
  -h|--help) sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "")        echo "usage: scripts/smoke-test.sh <stage>" >&2; exit 2 ;;
  -*)        echo "unknown option: $1" >&2; exit 2 ;;
esac

STAGE="$1"
shift
[ $# -eq 0 ] || { echo "ERROR: unexpected argument: $1" >&2; exit 2; }

command -v curl >/dev/null || { echo "ERROR: curl not found in PATH" >&2; exit 1; }
command -v jq   >/dev/null || { echo "ERROR: jq not found in PATH" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TFVARS="$ROOT/terraform/envs/$STAGE/platform/terraform.tfvars"

[ -f "$TFVARS" ] || {
  echo "ERROR: no such stage '$STAGE': $TFVARS does not exist" >&2
  exit 1
}

SUFFIX="$(sed -n 's/^hostname_suffix[[:space:]]*=[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$TFVARS")"
[ -n "$SUFFIX" ] || {
  echo "ERROR: no hostname_suffix in $TFVARS" >&2
  exit 1
}

# service : hostname label : health path : serves a did:web document
#
# Health paths disagree per service, which is why this is a table and not a
# constant. The hostname label is spelled out for the same reason: openbao is
# reached at ssm.<suffix>.
#
# openbao's path omits the uninitcode=200 the ALB health check passes. ECS has to
# keep a fresh task alive for the provision Lambda to initialise it; a stage that
# has been deployed and is still uninitialised is a failure, and 501 says so.
#
# piri-signing-service takes a did:web through SIGNING_SERVICE_SERVICE_DID but
# serves no document at it, so its DID resolves nowhere. Nothing resolves it
# today: it is the only service no other service addresses by DID.
#
# plc has no identity of its own to publish, so its route gets the health check
# alone. Its public hostname is what an appliance Ingot reaches; the services in
# the VPC call it over private DNS, which this cannot see.
SERVICES=(
  "sprue:upload:/health:yes"
  "hilt:auth:/health:yes"
  "swarf:revoke:/health:yes"
  "delegator:delegator:/healthcheck:yes"
  "signing-service:signer:/healthcheck:no"
  "openbao:ssm:/v1/sys/health?standbyok=true:no"
  "plc:plc:/_health:no"
)

# Every request is bounded. A hung smoke test is worse than a failing one, and
# swarf serves a long-lived SSE stream on a route next to the one checked here.
#
# No --show-error: curl's own diagnostic would land in the middle of the results,
# and every failure below already names the service, the URL and the reason.
CURL=(curl --silent --max-time 10)

PASS='  ✓'
FAIL='  ✗'

pass() { printf '%s %s\n' "$PASS" "$1"; }
fail() { printf '%s %s\n' "$FAIL" "$1"; }

# check_health <hostname> <path>
check_health() {
  local host="$1" path="$2" url status
  url="https://${host}${path}"

  # curl writes 000 itself when it never saw a status line, and exits non-zero
  # while doing it, so the status is read from the output rather than the code.
  status="$("${CURL[@]}" --output /dev/null --write-out '%{http_code}' "$url" 2>/dev/null || true)"

  case "$status" in
    200)     pass "$url" ;;
    000|"")  fail "$url — no response (DNS, TLS or timeout)" ;;
    *)       fail "$url — HTTP $status" ;;
  esac
}

# check_did <hostname> — the document must claim the DID built from the hostname
# it was served from, or the service is running an identity nothing registered.
check_did() {
  local host="$1" url expected actual body
  url="https://${host}/.well-known/did.json"
  expected="did:web:${host}"

  if ! body="$("${CURL[@]}" --fail "$url" 2>/dev/null)"; then
    fail "$url — not served"
    return
  fi

  actual="$(jq -r '.id // empty' <<<"$body" 2>/dev/null || true)"

  if [ -z "$actual" ]; then
    fail "$url — no id in the document"
  elif [ "$actual" = "$expected" ]; then
    pass "$url — $actual"
  else
    fail "$url — publishes $actual, expected $expected"
  fi
}

# check_service <hostname label> <health path> <serves did>
check_service() {
  local path="$2" serves_did="$3" host="${1}.${SUFFIX}"

  check_health "$host" "$path"

  if [ "$serves_did" = "yes" ]; then
    check_did "$host"
  else
    echo "  – did.json not checked: this service serves no did document"
  fi
}

echo "=== Smoke-test the ${STAGE} stage ==="
echo "  Hostnames: <service>.${SUFFIX}, openbao at ssm.${SUFFIX}"
echo

# One job per service. A service whose target group has nothing healthy answers
# at once, but one whose task accepts the connection and never replies waits out
# the full --max-time, and several of those in sequence is a minute of nothing.
# Each job writes to its own file and the results are printed in table order
# afterwards, so a parallel run reads exactly like a sequential one.
results="$(mktemp -d)"
trap 'rm -rf "$results"' EXIT

for entry in "${SERVICES[@]}"; do
  IFS=: read -r service label path serves_did <<<"$entry"
  check_service "$label" "$path" "$serves_did" >"$results/$service" 2>&1 &
done

wait

for entry in "${SERVICES[@]}"; do
  service="${entry%%:*}"
  echo "$service"
  cat "$results/$service"
  echo
done

failures="$(cat "$results"/* | grep -c "^${FAIL} " || true)"

if [ "$failures" -gt 0 ]; then
  echo "FAILED: $failures check(s)"
  exit 1
fi

echo "OK: every check passed"
