#!/usr/bin/env bash
# Fail if any alert rule in a plan of terraform/envs/grafana does not route
# through Forge's notification policy tree, and name the rules that don't.
#
# A rule without notification_settings.policy falls through to the stack's
# default tree, which is FilOne's. The check reads the plan rather than the HCL
# because OpenTofu has no expression for every resource of a type, so a check in
# the configuration would need its own list of rule groups to keep up to date.
# This one covers every grafana_rule_group the plan holds.
#
# Takes the output of `tofu show -json` on a saved plan, as a file or on stdin.
# plan-grafana runs it on every pull request.
set -euo pipefail

plan="$(cat "${1:-/dev/stdin}")"
resources='[.planned_values.root_module | recurse(.child_modules[]?) | .resources[]?]'

policy="$(jq -r "$resources"' | .[] | select(.address == "grafana_apps_notifications_routingtree_v1beta1.forge") | .values.metadata.uid' <<<"$plan")"
if [ -z "$policy" ]; then
  echo "The plan has no grafana_apps_notifications_routingtree_v1beta1.forge to route to." >&2
  exit 1
fi

unrouted="$(jq -r --arg policy "$policy" "$resources"' | .[]
  | select(.type == "grafana_rule_group") | .values.rule[]
  | select((.notification_settings[0].policy // null) != $policy)
  | .name' <<<"$plan")"
if [ -n "$unrouted" ]; then
  echo "Rules not routed through Forge's notification policy tree; set notification_settings { policy = local.forge_policy } on each:" >&2
  while IFS= read -r name; do printf '  %s\n' "$name"; done <<<"$unrouted" >&2
  exit 1
fi
