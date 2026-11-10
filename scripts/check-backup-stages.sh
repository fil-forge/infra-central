#!/usr/bin/env bash
# Fail if appliance_backup_stages in the grafana root disagrees with the
# platform roots about which stages take appliance backups.
#
# A stage takes backups when its platform root sets appliance_backups to
# something other than null. The grafana root cannot read that: it keeps its
# own state and reads no other root's, and prod's platform state is in another
# account. So it keeps its own list, and CI compares the two. A stage missing
# from the list would get no stale-snapshot alert; a stage on it that takes no
# backups would get one that fires forever.
#
# Only alert_stages are compared, because nothing alerts on any other stage.
#
# Reads files only: no AWS or Grafana credentials, no network.
set -euo pipefail

tfvars="terraform/envs/grafana/terraform.tfvars"

# The single-line list form terraform.tfvars uses, as check-stage-picker.sh
# reads alert_stages.
read_list() {
  sed -n "s/^$1 *= *\[\(.*\)\]/\1/p" "$tfvars" | tr -d ' "' | tr ',' '\n' | sed '/^$/d' | sort
}

alert_stages="$(read_list alert_stages)"
if [ -z "$alert_stages" ]; then
  echo "could not read alert_stages from $tfvars" >&2
  exit 1
fi
if ! grep -q '^appliance_backup_stages *= *\[' "$tfvars"; then
  echo "could not read appliance_backup_stages from $tfvars" >&2
  exit 1
fi
listed="$(read_list appliance_backup_stages)"

configured=""
for stage in $alert_stages; do
  root="terraform/envs/$stage/platform"
  if [ ! -d "$root" ]; then
    echo "alert_stages names $stage, but $root does not exist" >&2
    exit 1
  fi
  # An uncommented assignment whose value is not null.
  if grep -hE '^[[:space:]]*appliance_backups[[:space:]]*=' "$root"/*.tf |
    grep -vqE '=[[:space:]]*null[[:space:]]*$'; then
    configured+="$stage"$'\n'
  fi
done
configured="$(printf '%s' "$configured" | sed '/^$/d' | sort)"

if [ "$listed" != "$configured" ]; then
  printf 'appliance_backup_stages in %s: %s\n' "$tfvars" "$(paste -sd' ' - <<<"$listed")" >&2
  printf 'alert_stages whose platform root sets appliance_backups: %s\n' \
    "$(paste -sd' ' - <<<"$configured")" >&2
  printf '\nEdit appliance_backup_stages to match.\n' >&2
  exit 1
fi
