#!/usr/bin/env bash
# Check a site's VPN connection to its stage's pandora cluster from the site's
# appliance host, before the appliance's own VPN provisioning exists.
#
# strongSwan and a psql client run in two containers. The tunnels, the site's
# private /32 and the source NAT live in the strongSwan container's network
# namespace, so the host's own network configuration is left alone.
#
# Runs on the host, as root, from /run/pandora-vpn-check, where
# `scripts/fetch-pandora-vpn-secrets.sh --host` puts it. Run it under ssh -t,
# because it waits for Enter before tearing down:
#
#   ssh -t root@23.83.66.244 /run/pandora-vpn-check/check-pandora-vpn-host.sh
#
# The checks run in order and stop at the first failure:
#   0. a container can use nftables on this host's kernel
#   1. both tunnels come up within 120 seconds
#   2. through tunnel 1, psql as pandora_storage_server prints 15s for
#      SHOW statement_timeout, with sslmode=verify-full
#   3. with tunnel 1 down and the route moved to tunnel 2, the same query works
#
# With both tunnels up again it prints the command that shows the tunnels'
# status on the AWS side. On exit, pass or fail, it prints the security
# associations and charon's last log lines, waits for Enter, then removes the
# containers, their network and images, and /run/pandora-vpn-check with the
# secrets.
#
# Nothing else may initiate IKE from this host while the check runs: two
# initiators from the same address compete for the same tunnels.
set -euo pipefail

CHECK_DIR=/run/pandora-vpn-check
COMPOSE_FILE="$CHECK_DIR/pandora-vpn-check/compose.yml"

case "${1:-}" in
  -h|--help) sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "")        ;;
  *)         echo "unknown option: $1" >&2; exit 2 ;;
esac

main() {
  [ "$(id -u)" = 0 ] || fail "run as root"
  [ -f "$CHECK_DIR/secrets/dsn" ] \
    || fail "$CHECK_DIR/secrets/dsn is missing; run scripts/fetch-pandora-vpn-secrets.sh --host first"
  command -v docker >/dev/null || fail "docker not found in PATH"

  # shellcheck source=/dev/null
  . "$CHECK_DIR/secrets/tunnels.env"
  echo "=== Check the ${STAGE} VPN connection for site ${SITE} ==="
  echo "  Tunnels:       $TUNNEL1_ADDRESS, $TUNNEL2_ADDRESS"
  echo "  Identity:      $CUSTOMER_GATEWAY_IP"
  echo "  Private /32:   $SITE_PRIVATE_IP"
  echo

  trap on_exit EXIT

  step "Building the image"
  compose build --quiet

  step "0. nftables in a container"
  compose run --rm --no-deps --entrypoint nft strongswan add table ip precheck \
    || fail "a container cannot use nftables here; strongswan-entrypoint.sh needs iptables SNAT and TCPMSS --clamp-mss-to-pmtu rules instead"

  step "1. Both tunnels up"
  compose up -d
  wait_for_tunnels 120

  step "2. psql through tunnel 1"
  check_query

  step "3. psql through tunnel 2"
  in_strongswan swanctl --terminate --ike tunnel1 >/dev/null || fail "could not take tunnel 1 down"
  route_via xfrm2
  check_query

  echo "Bringing tunnel 1 back…"
  route_via xfrm1
  in_strongswan swanctl --initiate --child tunnel1 --timeout 60 >/dev/null \
    || fail "tunnel 1 did not come back up"
  wait_for_tunnels 60

  echo
  echo "All checks passed. Both tunnels are up. On a laptop with AWS credentials,"
  echo "this prints UP twice once AWS has seen them:"
  echo
  echo "  aws ec2 describe-vpn-connections --filters Name=tag:Name,Values=${VPN_CONNECTION_NAME} --query 'VpnConnections[0].VgwTelemetry[].Status' --output text"
}

compose() {
  docker compose -f "$COMPOSE_FILE" "$@"
}

in_strongswan() {
  compose exec -T strongswan "$@"
}

# wait_for_tunnels <seconds> — wait until both IKE SAs are established and both
# CHILD_SAs installed.
wait_for_tunnels() {
  local deadline=$((SECONDS + $1)) sas
  while :; do
    sas="$(in_strongswan swanctl --list-sas 2>/dev/null || true)"
    if tunnel_up 1 "$sas" && tunnel_up 2 "$sas"; then
      echo "  ✓ both tunnels up"
      return
    fi
    [ "$SECONDS" -lt "$deadline" ] || fail "both tunnels were not up within $1 seconds"
    sleep 2
  done
}

# tunnel_up <n> <list-sas output>
tunnel_up() {
  grep -Eq "^tunnel$1: #[0-9]+, ESTABLISHED" <<<"$2" \
    && grep -Eq "^  tunnel$1: #[0-9]+, reqid [0-9]+, INSTALLED" <<<"$2"
}

# route_via <xfrm interface> — point the VPC route at one tunnel.
route_via() {
  in_strongswan sh -c ". /secrets/tunnels.env && ip route replace \"\$VPC_ROUTE\" dev $1 src \"\$SITE_PRIVATE_IP\"" \
    || fail "could not route the VPC through $1"
}

check_query() {
  local result
  # shellcheck disable=SC2016 # the DSN is read inside the container
  result="$(compose exec -T client sh -c 'psql "$(cat /run/pandora/dsn)" -XAtc "SHOW statement_timeout"')" \
    || fail "psql could not query the cluster"
  [ "$result" = 15s ] || fail "expected statement_timeout 15s, got '$result'"
  echo "  ✓ statement_timeout is 15s"
}

step() {
  echo
  echo "--- $* ---"
}

on_exit() {
  local status=$?
  cd /

  echo
  echo "--- Security associations ---"
  in_strongswan swanctl --list-sas 2>/dev/null || true
  echo "--- Last charon log lines ---"
  compose logs --no-log-prefix --tail 40 strongswan 2>/dev/null || true
  echo
  if [ "$status" = 0 ]; then
    echo "PASSED"
  else
    echo "FAILED"
  fi

  read -r -p "Press Enter to remove the containers and the secrets… " _ </dev/tty || true
  compose down --rmi local --volumes --remove-orphans || true
  rm -rf "$CHECK_DIR"
  exit "$status"
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

main
