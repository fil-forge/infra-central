# Agent Guidelines

## Observability

When a change adds or alters something that runs, decide how on-call would
know it had broken, and add that in the same PR where it is useful: an alert,
a dashboard panel, or a line in `docs/observability.md`. Appliance services'
alerts and panels live here too. Skip it for changes nothing operational
depends on. "Adding an alert or panel" in `docs/observability.md` says how to
do each.
