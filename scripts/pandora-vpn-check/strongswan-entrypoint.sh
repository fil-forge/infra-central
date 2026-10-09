#!/usr/bin/env bash
# Runs strongSwan for scripts/check-pandora-vpn-host.sh and
# scripts/check-pandora-vpn-laptop.sh. Everything it changes lives in the
# container's network namespace and goes away with the container.
#
# ROLE=host    creates one xfrm interface per tunnel, puts the site's private
#              /32 on a dummy interface, routes the VPC side into tunnel 1,
#              source-NATs the client container to the /32 and clamps the TCP
#              MSS, then brings both tunnels up and keeps retrying them.
# ROLE=laptop  only attempts IKE with both tunnels, a few retransmits each, so
#              the laptop check can tell whether AWS answers a peer at another
#              address.
#
# Reads /secrets/tunnels.env, /secrets/psk1 and /secrets/psk2, written by
# scripts/fetch-pandora-vpn-secrets.sh. The keys are written into
# /etc/swanctl/conf.d, which must be a tmpfs so they stay off the disk.
set -euo pipefail

SECRETS_DIR=/secrets
SWANCTL_CONF=/etc/swanctl/conf.d/pandora-vpn-check.conf

# The runbook's tunnel MTU behind NAT. Docker masquerades the host check, and
# the laptop is behind NAT too.
TUNNEL_MTU=1438

main() {
  load_tunnels
  case "${ROLE:-}" in
    host)
      [ -n "${CLIENT_IP:-}" ] || fail "CLIENT_IP is not set"
      [ -n "${VPC_ROUTE:-}" ] || fail "VPC_ROUTE is not set"
      setup_host_network
      ;;
    laptop)
      # Give up after three tries of each IKE_SA_INIT, about 25 seconds,
      # instead of the default five tries over about 165 seconds.
      printf 'charon {\n  retransmit_tries = 2\n}\n' > /etc/strongswan.d/zz-laptop.conf
      ;;
    *)
      fail "ROLE must be host or laptop, got '${ROLE:-}'"
      ;;
  esac
  write_swanctl_conf
  run_charon
}

load_tunnels() {
  # shellcheck source=/dev/null
  . "$SECRETS_DIR/tunnels.env"
  for name in CUSTOMER_GATEWAY_IP TUNNEL1_ADDRESS TUNNEL2_ADDRESS SITE_PRIVATE_IP; do
    [[ "${!name:-}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] \
      || fail "$name in $SECRETS_DIR/tunnels.env is not an IPv4 address: '${!name:-}'"
  done
  for n in 1 2; do
    [ -s "$SECRETS_DIR/psk$n" ] || fail "$SECRETS_DIR/psk$n is missing or empty"
  done
}

setup_host_network() {
  local uplink
  uplink="$(ip -4 route show default | awk '{ print $5; exit }')"
  [ -n "$uplink" ] || fail "no default route in the container"

  for n in 1 2; do
    ip link add "xfrm$n" type xfrm dev "$uplink" if_id "$n"
    ip link set "xfrm$n" mtu "$TUNNEL_MTU" up
  done

  ip link add site type dummy
  ip addr add "$SITE_PRIVATE_IP/32" dev site
  ip link set site up

  ip route add "$VPC_ROUTE" dev xfrm1 src "$SITE_PRIVATE_IP"

  nft -f - <<EOF
table ip pandora_vpn_check {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    oifname "xfrm*" ip saddr $CLIENT_IP snat to $SITE_PRIVATE_IP
  }
  chain forward {
    type filter hook forward priority mangle; policy accept;
    tcp flags syn / syn,rst tcp option maxseg size set rt mtu
  }
}
EOF
}

write_swanctl_conf() {
  grep -qs ' /etc/swanctl/conf.d tmpfs ' /proc/mounts \
    || fail "/etc/swanctl/conf.d is not a tmpfs; refusing to write the keys to disk"

  local keyingtries=0 dpd_action=restart
  if [ "$ROLE" = laptop ]; then
    keyingtries=1
    dpd_action=clear
  fi

  umask 077
  {
    echo "connections {"
    for n in 1 2; do
      local address_var="TUNNEL${n}_ADDRESS"
      cat <<EOF
  tunnel$n {
    version = 2
    remote_addrs = ${!address_var}
    proposals = aes256gcm16-prfsha384-ecp384-ecp521
    keyingtries = $keyingtries
    mobike = no
    dpd_delay = 10s
    local {
      auth = psk
      id = $CUSTOMER_GATEWAY_IP
    }
    remote {
      auth = psk
      id = ${!address_var}
    }
    children {
      tunnel$n {
        local_ts = 0.0.0.0/0
        remote_ts = 0.0.0.0/0
        esp_proposals = aes256gcm16-ecp384-ecp521
        if_id_in = $n
        if_id_out = $n
        start_action = start
        dpd_action = $dpd_action
      }
    }
  }
EOF
    done
    echo "}"
    echo "secrets {"
    for n in 1 2; do
      local address_var="TUNNEL${n}_ADDRESS"
      cat <<EOF
  ike-tunnel$n {
    id-1 = $CUSTOMER_GATEWAY_IP
    id-2 = ${!address_var}
    secret = 0s$(base64 -w0 < "$SECRETS_DIR/psk$n")
  }
EOF
    done
    echo "}"
  } > "$SWANCTL_CONF"
}

run_charon() {
  /usr/sbin/charon-systemd &
  local charon_pid=$!
  trap 'kill -TERM "$charon_pid" 2>/dev/null' TERM INT

  local tries=0
  until swanctl --stats >/dev/null 2>&1; do
    tries=$((tries + 1))
    [ "$tries" -lt 50 ] || fail "charon did not open its vici socket within 10 seconds"
    sleep 0.2
  done
  swanctl --load-all

  wait "$charon_pid"
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

main "$@"
