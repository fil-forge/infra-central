#!/usr/bin/env bash
# Fail if the dashboards' stage picker and alert_stages have drifted apart.
#
# There is one list of stages and one rule about it: the picker is alert_stages
# with dev in front. dev exists and is worth looking at, but nothing alerts on
# it -- it runs no cAdvisor, and the container rules say so -- so it is the
# standing exception rather than a second list to keep in step.
#
# They cannot be one file. The dashboards carry Grafana's own ${...}
# interpolation, so templatefile() cannot generate them, and Terraform patching
# the picker at apply time would leave the committed files wrong for the PR
# previews, which read them as they are. So CI compares the two instead: adding
# a stage to terraform.tfvars and not to the pickers fails here rather than
# silently alerting on a stage no dashboard offers.
#
# Reads files only: no Grafana credentials, no network.
set -euo pipefail

root="terraform/envs/grafana"
tfvars="$root/terraform.tfvars"

# The single-line list form terraform.tfvars uses. A multi-line list would parse
# to nothing and fail the comparison below, which is the right way round: a
# confusing failure beats a silent pass.
stages="$(sed -n 's/^alert_stages *= *\[\(.*\)\]/\1/p' "$tfvars" | tr -d ' "')"
if [ -z "$stages" ]; then
  echo "could not read alert_stages from $tfvars" >&2
  exit 1
fi
expected="dev,$stages"

status=0
for file in "$root"/dashboards/*.json; do
  actual="$(jq -r '.spec.variables[] | select(.spec.name == "stage") | .spec.query' "$file")"
  if [ "$actual" != "$expected" ]; then
    printf '%s\n  stage picker: %s\n  alert_stages + dev: %s\n' "$file" "$actual" "$expected" >&2
    status=1
  fi
done

if [ "$status" -ne 0 ]; then
  printf '\nEdit the stage variable in each dashboard, or alert_stages in %s.\n' "$tfvars" >&2
fi
exit "$status"
