#!/usr/bin/env bash
# Fail if expected_appliances in the grafana root disagrees with the
# appliance_regions of the alert stages' platform roots.
#
# The rules that read absence need to know which appliances should be alive:
# from metrics alone a retired appliance and a dead one look the same, because
# both stop reporting. The platform roots say which regions are live, but the
# grafana root reads no other root's state, and prod's platform state is in
# another account. So it keeps its own list of <stage>-<region> labels, and CI
# compares the two. A live region missing from the list goes unwatched; a
# retired one left on it pages as a node that stopped reporting.
#
# Reads files only: no AWS or Grafana credentials, no network.
set -euo pipefail

grafana_tfvars="terraform/envs/grafana/terraform.tfvars"

# The single-line list form the tfvars files use. A missing line is an empty
# list, which is how prod states that it has no regions yet.
read_list() {
  sed -n "s/^$1 *= *\[\(.*\)\]/\1/p" "$2" | tr -d ' "' | tr ',' '\n' | sed '/^$/d'
}

alert_stages="$(read_list alert_stages "$grafana_tfvars")"
if [ -z "$alert_stages" ]; then
  echo "could not read alert_stages from $grafana_tfvars" >&2
  exit 1
fi
if ! grep -q '^expected_appliances *= *\[' "$grafana_tfvars"; then
  echo "could not read expected_appliances from $grafana_tfvars" >&2
  exit 1
fi
listed="$(read_list expected_appliances "$grafana_tfvars" | sort)"

live=""
for stage in $alert_stages; do
  tfvars="terraform/envs/$stage/platform/terraform.tfvars"
  if [ ! -f "$tfvars" ]; then
    echo "alert_stages names $stage, but $tfvars does not exist" >&2
    exit 1
  fi
  if grep '^appliance_regions *=' "$tfvars" | grep -vq '^appliance_regions *= *\[.*\] *$'; then
    echo "$tfvars sets appliance_regions in a form other than a single-line list" >&2
    exit 1
  fi
  for region in $(read_list appliance_regions "$tfvars"); do
    live+="$stage-$region"$'\n'
  done
done
live="$(printf '%s' "$live" | sed '/^$/d' | sort)"

if [ "$listed" != "$live" ]; then
  printf 'expected_appliances in %s: %s\n' "$grafana_tfvars" "$(paste -sd' ' - <<<"$listed")" >&2
  printf 'appliance_regions of the alert stages: %s\n' "$(paste -sd' ' - <<<"$live")" >&2
  printf '\nEdit expected_appliances to match.\n' >&2
  exit 1
fi
