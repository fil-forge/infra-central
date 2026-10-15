# Agent Guidelines

## Observability

When a change adds or alters something that runs, decide how on-call would
know it had broken, and add that in the same PR where it is useful.
`docs/observability.md` describes what ships to Grafana and how alerts are
routed.

- **Alerts** go in `terraform/envs/grafana/alerts.tf`, in the rule group for
  the component. Each rule needs:
  - `team_name = "forge"`;
  - a `severity` chosen by the definitions in `docs/observability.md`;
  - `stage` when it watches a stage;
  - `notification_settings { policy = local.forge_policy }`.

  CI's `scripts/check-alert-routing.sh` fails the Grafana plan when a rule
  isn't routed. Add new rules at the end of their group, because the provider
  keeps each rule's uid by its position. Add a row to the rule table in
  `docs/observability.md`.
- **Dashboard panels** go in the JSON under
  `terraform/envs/grafana/dashboards/`. Edit in the UI, export, run
  `scripts/normalise-dashboard.sh`, and commit the result; `make check`
  rejects a file that isn't normalised. Link a rule to its panel with
  `dashboard_url`, `__dashboardUid__` and `__panelId__`, as the existing rules
  do.
- **Telemetry.** Central's CloudWatch logs and AWS service metrics already
  ship to Grafana. Application metrics don't yet, so a feature whose health
  can only be seen from inside a service needs that service to export the
  metric first.

Appliance services (Piri, Ingot and the rest) export their own telemetry,
which fil-forge/infra-nodes ships; their alerts and panels still live here.
