#!/usr/bin/env bash
# Check that a site's VPN connection establishes no tunnel with any address but
# the site's own.
#
# Runs strongSwan in a container on this laptop with the site's real tunnel
# addresses, its customer gateway identity and both real pre-shared keys, and
# passes if neither tunnel establishes. AWS should not even answer the first
# IKE message, because it comes from an address other than the customer
# gateway's. A firewall that drops UDP 500 or 4500 on this laptop's path looks
# the same, so a run that AWS did not answer shows only that no tunnel
# established; one that AWS answered and refused shows that AWS checked the
# attempt. The charon lines printed at the end show which. The keys stay in a
# temporary directory that is deleted on exit.
#
# It needs no database access: the cluster has no public address, so a psql
# attempt from here would prove nothing.
#
# Usage:
#   scripts/check-pandora-vpn-laptop.sh --stage prod --site provisional
#
# Options:
#   --stage   stage the site belongs to         (required)
#   --site    the site's key in pandora_sites   (required)
#
# Prerequisites:
#   - AWS credentials and region for the account holding the stage
#   - aws, jq, curl and a running Docker
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE=pandora-vpn-check:laptop
CONTAINER=pandora-vpn-check-laptop

# With retransmit_tries = 2, charon gives up on an unanswered IKE_SA_INIT after
# about 25 seconds. A refusal from AWS ends the attempt at once.
TIMEOUT_SECONDS=60

STAGE=""
SITE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --stage)   STAGE="$2"; shift 2 ;;
    --site)    SITE="$2"; shift 2 ;;
    -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[ -n "$STAGE" ] || { echo "ERROR: --stage is required" >&2; exit 2; }
[ -n "$SITE" ]  || { echo "ERROR: --site is required" >&2; exit 2; }

command -v docker >/dev/null || { echo "ERROR: docker not found in PATH" >&2; exit 1; }

main() {
  WORKDIR="$(mktemp -d)"
  trap cleanup EXIT

  "$SCRIPT_DIR/fetch-pandora-vpn-secrets.sh" --stage "$STAGE" --site "$SITE" --out "$WORKDIR/secrets"
  # shellcheck source=/dev/null
  . "$WORKDIR/secrets/tunnels.env"

  local public_ip
  public_ip="$(curl -fsS https://checkip.amazonaws.com)" || fail "could not read this laptop's public address"
  [ "$public_ip" != "$CUSTOMER_GATEWAY_IP" ] \
    || fail "this laptop's public address is the customer gateway's, ${CUSTOMER_GATEWAY_IP}; run the check from elsewhere"

  echo
  echo "=== Attempt IKE for the ${STAGE} site ${SITE} from ${public_ip} ==="
  echo "  Tunnels:   $TUNNEL1_ADDRESS, $TUNNEL2_ADDRESS"
  echo "  Identity:  $CUSTOMER_GATEWAY_IP"
  echo

  docker build --quiet --tag "$IMAGE" "$SCRIPT_DIR/pandora-vpn-check" >/dev/null
  docker run --detach --name "$CONTAINER" \
    --cap-add NET_ADMIN \
    --env ROLE=laptop \
    --volume "$WORKDIR/secrets:/secrets:ro" \
    --tmpfs /etc/swanctl/conf.d:mode=0700 \
    --entrypoint strongswan-entrypoint.sh \
    "$IMAGE" >/dev/null

  # keyingtries = 1 for this role, so charon deletes an IKE SA when its attempt
  # ends, whether retransmits ran out or AWS refused it, and does not retry.
  # Both attempts are over once both have started and no SA is left. The logs
  # are read first: an SA exists before its "initiating" line is logged.
  local deadline=$((SECONDS + TIMEOUT_SECONDS)) logs sas
  while :; do
    logs="$(docker logs "$CONTAINER" 2>&1)"
    sas="$(docker exec "$CONTAINER" swanctl --list-sas 2>/dev/null)" || sas=""
    if grep -q ESTABLISHED <<<"$sas"; then
      print_ike_log
      fail "AWS established an IKE SA with ${public_ip}, which is not the site's address"
    fi
    if grep -q 'initiating IKE_SA tunnel1\[' <<<"$logs" \
      && grep -q 'initiating IKE_SA tunnel2\[' <<<"$logs" \
      && ! grep -q 'IKEv2' <<<"$sas"; then
      break
    fi
    [ "$SECONDS" -lt "$deadline" ] || { print_ike_log; fail "charon neither established nor ended both attempts within ${TIMEOUT_SECONDS} seconds"; }
    sleep 2
  done

  logs="$(docker logs "$CONTAINER" 2>&1)"
  print_ike_log
  echo
  if grep -q 'received packet' <<<"$logs"; then
    echo "PASSED: AWS answered and refused; the lines above show how."
  else
    echo "PASSED, NO ANSWER: no tunnel established and AWS did not answer either tunnel."
    echo "AWS ignores an unknown peer, and a firewall dropping UDP 500 or 4500 on this"
    echo "laptop's path looks the same, so this run does not show that AWS saw the attempt."
  fi
}

print_ike_log() {
  echo "--- charon ---"
  docker logs "$CONTAINER" 2>&1 \
    | grep -E 'initiating IKE_SA|sending packet|received packet|retransmit|giving up|establishing|authentication' \
    || true
}

cleanup() {
  docker rm --force "$CONTAINER" >/dev/null 2>&1 || true
  docker rmi "$IMAGE" >/dev/null 2>&1 || true
  rm -rf "$WORKDIR"
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

main
