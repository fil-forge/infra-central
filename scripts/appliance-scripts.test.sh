#!/usr/bin/env bash
# Tests for the scripts that read `appliances` from the platform tfvars:
# mint-appliance-credentials.sh and check-appliance-regions.sh. Each case runs
# the real script in a scratch copy of the repo layout, with a stub `aws` that
# records its calls and fails, so nothing reaches AWS.
#
# Reads files only: no AWS credentials, no network.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
failures=0

# new_tree — a scratch repo with the scripts under test and a stub aws.
new_tree() {
  local tree
  tree="$(mktemp -d)"
  mkdir -p "$tree/scripts/lib" "$tree/bin" "$tree/terraform/envs/grafana"
  cp "$here/mint-appliance-credentials.sh" "$here/check-appliance-regions.sh" "$tree/scripts/"
  cp "$here/lib/appliances.sh" "$tree/scripts/lib/"
  cat >"$tree/bin/aws" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$(dirname "$0")/aws-calls"
exit 1
EOF
  chmod +x "$tree/bin/aws"
  echo "$tree"
}

# platform_tfvars <tree> <stage> <body> — the stage's platform tfvars.
platform_tfvars() {
  mkdir -p "$1/terraform/envs/$2/platform"
  printf '%s\n' "$3" >"$1/terraform/envs/$2/platform/terraform.tfvars"
}

grafana_tfvars() {
  printf '%s\n' "$2" >"$1/terraform/envs/grafana/terraform.tfvars"
}

# expect <name> <want-status> <got-status> <output> <want-substring>
expect() {
  if [ "$2" != "$3" ] || ! grep -qF -- "$5" <<<"$4"; then
    printf 'FAIL: %s\n  want exit %s and output containing %q\n  got exit %s:\n%s\n' "$1" "$2" "$5" "$3" "$4" >&2
    failures=$((failures + 1))
  else
    printf 'ok: %s\n' "$1"
  fi
}

two_appliances='appliances = {
  any-region   = "203.0.113.7"
  other-region = "198.51.100.9"
}
retired_appliance_regions = ["retired-region"]'

# mint: the address comes from the stage's appliances map.
tree="$(new_tree)"
platform_tfvars "$tree" any-stage "$two_appliances"
status=0
out="$(PATH="$tree/bin:$PATH" "$tree/scripts/mint-appliance-credentials.sh" --stage any-stage --region other-region --yes 2>&1)" || status=$?
expect "mint binds the token to the region's address from appliances" 1 "$status" "$out" "Bound to: 198.51.100.9/32"

# mint: a region the map does not list stops before any AWS call.
tree="$(new_tree)"
platform_tfvars "$tree" any-stage "$two_appliances"
status=0
out="$(PATH="$tree/bin:$PATH" "$tree/scripts/mint-appliance-credentials.sh" --stage any-stage --region unlisted-region --yes 2>&1)" || status=$?
expect "mint refuses a region appliances does not list" 2 "$status" "$out" "unlisted-region"
if [ -e "$tree/bin/aws-calls" ]; then
  echo "FAIL: mint called aws for a region appliances does not list" >&2
  failures=$((failures + 1))
fi

# mint: --node-ip and --node-cidr still override the map.
tree="$(new_tree)"
platform_tfvars "$tree" any-stage "$two_appliances"
status=0
out="$(PATH="$tree/bin:$PATH" "$tree/scripts/mint-appliance-credentials.sh" --stage any-stage --region any-region --node-ip 192.0.2.1 --yes 2>&1)" || status=$?
expect "mint binds to --node-ip over the map" 1 "$status" "$out" "Bound to: 192.0.2.1/32"
status=0
out="$(PATH="$tree/bin:$PATH" "$tree/scripts/mint-appliance-credentials.sh" --stage any-stage --region any-region --node-cidr 192.0.2.0/29 --yes 2>&1)" || status=$?
expect "mint binds to --node-cidr over the map" 1 "$status" "$out" "Bound to: 192.0.2.0/29"

# check-appliance-regions: live_appliances matches every stage's map keys.
tree="$(new_tree)"
platform_tfvars "$tree" any-stage "$two_appliances"
platform_tfvars "$tree" other-stage 'appliances = {}'
grafana_tfvars "$tree" 'alert_stages = ["any-stage", "other-stage"]
live_appliances = ["any-stage-any-region", "any-stage-other-region"]'
status=0
out="$(cd "$tree" && scripts/check-appliance-regions.sh 2>&1)" || status=$?
expect "region check passes when live_appliances names every appliance" 0 "$status" "$out" ""

# check-appliance-regions: an appliance missing from live_appliances fails.
grafana_tfvars "$tree" 'alert_stages = ["any-stage", "other-stage"]
live_appliances = ["any-stage-any-region"]'
status=0
out="$(cd "$tree" && scripts/check-appliance-regions.sh 2>&1)" || status=$?
expect "region check fails when live_appliances misses an appliance" 1 "$status" "$out" "any-stage-other-region"

[ "$failures" -eq 0 ] || { echo "$failures failed" >&2; exit 1; }
