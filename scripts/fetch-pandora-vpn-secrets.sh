#!/usr/bin/env bash
# Fetch what scripts/check-pandora-vpn-host.sh and
# scripts/check-pandora-vpn-laptop.sh need for one site, printing none of it:
# the VPN connection's tunnel addresses, the customer gateway's IP, the site's
# private address and both pre-shared keys, and for the host check also the
# pandora_storage_server DSN and the RDS CA bundle.
#
# With --out, writes the files into a new directory, for the laptop check. The
# DSN is not fetched, because the laptop check never queries the database.
#
# With --host, copies the files and the host check to /run/pandora-vpn-check
# on the site's appliance host, and keeps no local copy.
#
# Usage:
#   scripts/fetch-pandora-vpn-secrets.sh --stage prod --site provisional \
#     --host root@23.83.66.244
#   scripts/fetch-pandora-vpn-secrets.sh --stage prod --site provisional \
#     --out "$dir"
#
# Options:
#   --stage   stage the site belongs to                  (required)
#   --site    the site's key in pandora_sites            (required)
#   --host    ssh target of the site's appliance host    (one of --host, --out)
#   --out     missing or empty directory to write into   (one of --host, --out)
#
# Prerequisites:
#   - AWS credentials and region for the account holding the stage
#   - aws, jq and curl; ssh and scp for --host
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOST_CHECK_DIR=/run/pandora-vpn-check
RDS_CA_BUNDLE_URL=https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem

STAGE=""
SITE=""
HOST=""
OUT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --stage)   STAGE="$2"; shift 2 ;;
    --site)    SITE="$2"; shift 2 ;;
    --host)    HOST="$2"; shift 2 ;;
    --out)     OUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

[ -n "$STAGE" ] || { echo "ERROR: --stage is required" >&2; exit 2; }
[ -n "$SITE" ]  || { echo "ERROR: --site is required" >&2; exit 2; }
if [ -n "$HOST" ] && [ -n "$OUT" ]; then
  echo "ERROR: pass only one of --host and --out" >&2
  exit 2
fi
if [ -z "$HOST" ] && [ -z "$OUT" ]; then
  echo "ERROR: one of --host and --out is required" >&2
  exit 2
fi

command -v aws  >/dev/null || fail "aws CLI not found in PATH"
command -v jq   >/dev/null || fail "jq not found in PATH"
command -v curl >/dev/null || fail "curl not found in PATH"

main() {
  umask 077

  local secrets_dir
  if [ -n "$OUT" ]; then
    mkdir -p "$OUT"
    [ -z "$(ls -A "$OUT")" ] || fail "$OUT is not empty"
    secrets_dir="$OUT"
  else
    WORKDIR="$(mktemp -d)"
    trap 'rm -rf "$WORKDIR"' EXIT
    secrets_dir="$WORKDIR/secrets"
    mkdir "$secrets_dir"
  fi

  echo "Reading the ${STAGE} VPN connection for site ${SITE}…"
  fetch_vpn "$secrets_dir"

  if [ -n "$HOST" ]; then
    echo "Reading the pandora_storage_server DSN and the RDS CA bundle…"
    fetch_database "$secrets_dir"
    copy_to_host "$secrets_dir"
  else
    echo "Wrote the tunnel addresses and keys to $OUT"
  fi
}

# fetch_vpn <dir> — write tunnels.env, psk1 and psk2.
fetch_vpn() {
  local dir="$1" tag connections connection cgw_id cgw_ip key_arn
  local tunnel1 tunnel2 private_cidr secret

  tag="fc-${STAGE}-pandora-vpn-${SITE}"
  connections="$(aws ec2 describe-vpn-connections \
    --filters "Name=tag:Name,Values=${tag}" "Name=state,Values=available" \
    --output json)" || fail "aws ec2 describe-vpn-connections failed"
  [ "$(jq '.VpnConnections | length' <<<"$connections")" = 1 ] \
    || fail "expected one available VPN connection tagged Name=${tag}"
  connection="$(jq '.VpnConnections[0]' <<<"$connections")"

  tunnel1="$(jq -r '.Options.TunnelOptions[0].OutsideIpAddress // empty' <<<"$connection")"
  tunnel2="$(jq -r '.Options.TunnelOptions[1].OutsideIpAddress // empty' <<<"$connection")"
  [ -n "$tunnel1" ] && [ -n "$tunnel2" ] || fail "the VPN connection does not list two tunnel addresses"

  # The connection's one static route is the site's private /32.
  private_cidr="$(jq -r '[.Routes[]? | select(.State == "available") | .DestinationCidrBlock] | if length == 1 then .[0] else empty end' <<<"$connection")"
  [[ "$private_cidr" == */32 ]] || fail "expected the VPN connection to have exactly one available /32 route, got '${private_cidr}'"

  cgw_id="$(jq -r '.CustomerGatewayId' <<<"$connection")"
  cgw_ip="$(aws ec2 describe-customer-gateways --customer-gateway-ids "$cgw_id" \
    --query 'CustomerGateways[0].IpAddress' --output text)" \
    || fail "aws ec2 describe-customer-gateways failed"

  cat > "$dir/tunnels.env" <<EOF
STAGE=${STAGE}
SITE=${SITE}
VPN_CONNECTION_NAME=${tag}
CUSTOMER_GATEWAY_IP=${cgw_ip}
TUNNEL1_ADDRESS=${tunnel1}
TUNNEL2_ADDRESS=${tunnel2}
SITE_PRIVATE_IP=${private_cidr%/32}
EOF

  key_arn="$(jq -r '.PreSharedKeyArn // empty' <<<"$connection")"
  [ -n "$key_arn" ] || fail "the VPN connection has no PreSharedKeyArn; are its keys in Secrets Manager?"
  secret="$(aws secretsmanager get-secret-value --secret-id "$key_arn" \
    --query SecretString --output text)" || fail "aws secretsmanager get-secret-value failed"

  # AWS keeps one secret per connection, a JSON object holding each tunnel's
  # key under the tunnel's outside address. On a mismatch print only the
  # object's key names, which are addresses, never its values.
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$secret" \
    || fail "the pre-shared key secret is not a JSON object"
  local n address
  for n in 1 2; do
    address="tunnel${n}"
    address="${!address}"
    jq -ej --arg address "$address" '.[$address] | strings' <<<"$secret" > "$dir/psk$n" \
      || fail "the pre-shared key secret has no string under ${address}; its keys are: $(jq -r 'keys | join(", ")' <<<"$secret")"
  done
}

# fetch_database <dir> — write dsn and global-bundle.pem.
fetch_database() {
  local dir="$1"
  aws ssm get-parameter --with-decryption \
    --name "/forge-central/${STAGE}/pandora-storage-server/postgres-dsn" \
    --query Parameter.Value --output text > "$dir/dsn" \
    || fail "aws ssm get-parameter failed"
  curl -fsS -o "$dir/global-bundle.pem" "$RDS_CA_BUNDLE_URL" \
    || fail "could not download $RDS_CA_BUNDLE_URL"
}

# copy_to_host <secrets dir> — copy the secrets and the host check to the host.
copy_to_host() {
  local secrets_dir="$1"
  command -v ssh >/dev/null || fail "ssh not found in PATH"
  command -v scp >/dev/null || fail "scp not found in PATH"

  echo "Copying the check and its secrets to ${HOST}:${HOST_CHECK_DIR}…"
  # /run is a tmpfs, so the keys and the DSN never reach the host's disk, and a
  # reboot clears them along with anything an interrupted check left behind.
  # shellcheck disable=SC2029 # the path is meant to expand here
  ssh "$HOST" "install -d -m 700 '$HOST_CHECK_DIR' && [ -z \"\$(ls -A '$HOST_CHECK_DIR')\" ]" \
    || fail "${HOST_CHECK_DIR} on ${HOST} is not empty; an earlier check left it behind. See docs/pandora-vpn.md for the cleanup."
  scp -rq "$secrets_dir" "$SCRIPT_DIR/pandora-vpn-check" "$SCRIPT_DIR/check-pandora-vpn-host.sh" \
    "${HOST}:${HOST_CHECK_DIR}/"

  echo
  echo "Run the check on the host:"
  echo "  ssh -t ${HOST} ${HOST_CHECK_DIR}/check-pandora-vpn-host.sh"
}

main
