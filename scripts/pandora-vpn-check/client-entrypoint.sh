#!/usr/bin/env bash
# Prepares the psql client for scripts/check-pandora-vpn-host.sh: routes the
# VPC side through the strongSwan container, and splits /secrets/dsn into a
# password file and a DSN without the password, both in the /run/pandora
# tmpfs. psql then reads the password from the file, so it never appears on a
# command line, which the host's ps would show.
set -euo pipefail

main() {
  [ -n "${STRONGSWAN_IP:-}" ] || fail "STRONGSWAN_IP is not set"
  [ -n "${VPC_ROUTE:-}" ] || fail "VPC_ROUTE is not set"
  grep -qs ' /run/pandora tmpfs ' /proc/mounts \
    || fail "/run/pandora is not a tmpfs; refusing to write the password to disk"

  ip route add "$VPC_ROUTE" via "$STRONGSWAN_IP"
  split_dsn

  exec sleep infinity
}

split_dsn() {
  local dsn re password
  dsn="$(cat /secrets/dsn)"
  re='^(postgres(ql)?://)([^:@/]+):([^@]*)@(.+)$'
  [[ "$dsn" =~ $re ]] || fail "/secrets/dsn is not of the form postgres://user:password@host:port/db?params"

  # The provision Lambda percent-encodes the password. .pgpass escapes only
  # backslash and colon.
  password="$(printf '%b' "${BASH_REMATCH[4]//%/\\x}")"
  password="${password//\\/\\\\}"
  password="${password//:/\\:}"

  umask 077
  printf '*:*:*:*:%s\n' "$password" > /run/pandora/pgpass
  printf '%s%s@%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[5]}" > /run/pandora/dsn
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

main "$@"
