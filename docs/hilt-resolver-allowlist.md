# Hilt inbound DID-resolution allowlist

FIL-1675 permits an unauthenticated UCAN container to select a `did:web`
issuer before its signature is verified. Hilt's `server.allowed_web_dids`
restricts that resolution to exact complete DID strings; the empty list denies
all external web resolution. This deployment change supplies the list through
`HILT_SERVER_ALLOWED_WEB_DIDS` on the actual Hilt ECS task.

## Source of allowed identities

The platform root already exports `appliance_keys`: transit-key names the vault
phase reports for live regions after reconciling `appliance_regions` and
`retired_appliance_regions`. Apps consumes that existing output together with
the existing content hostname suffix. The provider-free `hilt-resolver-policy`
module validates the `appliance-unseal-<region>` name shape and derives a unique
sorted list of `did:web:s3.<region>.<ingot_hostname_suffix>`, matching the provision
Lambda's onboarding identities. No wildcard, generic internet host, Sprue or
Swarf identity is added. Hilt's own DID resolves locally; did:key does not use
this HTTP resolver. Outgoing Sprue/Swarf clients are separate from the inbound
UCAN validator.

The committed node inventory identifies the dev caller as
`did:web:s3.us-east-9.latest.dev.filonecontent.com` and the staging caller as
`did:web:s3.eu-central-3.staging.filonecontent.com`. These are source references,
not an attestation of live provider registration. The task list is derived from
each stage's platform inventory, not copied from these examples. A stage with
no live appliances sets an empty list rather than allowing all hosts.

## Perimeter evidence

Committed deployment source routes Hilt's public `auth.<hostname_suffix>` host
through the public HTTPS load balancer:

- `modules/apps/main.tf` assigns Hilt a public hostname and listener.
- `modules/shared/ecs-service/routing.tf` forwards that hostname to Hilt without
  a path restriction or listener authentication action.
- `modules/platform/network/main.tf` admits public port 443 from `0.0.0.0/0` to
  the load balancer. Tasks admit the load balancer on service ports.
- The listener in `modules/platform/ingress/main.tf` terminates HTTPS; tasks have
  NAT egress for external DID documents.

Thus the committed configuration does not support treating UCAN `POST /` as
Ingot-only or perimeter-internal. This review did not inspect live AWS rules,
issue an exploit request or establish reachability beyond source configuration.

## Rollout order

1. Review the Hilt service change and this configuration change together.
   Supply `HILT_SERVER_ALLOWED_WEB_DIDS` in the **same ECS task-definition
   revision as the patched image**, or configure the environment on the old
   image first and then replace it with the patched image. Do not deploy the
   new fail-closed image against an old task definition that omits its list:
   legitimate Ingot requests would be denied. Old binaries ignore the new
   environment variable, so configuration alone is not a mitigation until the
   patched image is running.
2. Keep the normal platform-before-apps ordering when changing the live region
   inventory. A new region reaches the allowed list once platform reconciliation
   reports its transit key. This change adds no remote-state output: PR apps
   plans can still read the last-applied platform contract. Do not substitute a
   fallback empty list for missing state output, which would hide a broken state
   contract and deny legitimate callers.
3. Review the apps plan's exact allowed list against the stage's registered
   Ingot providers. A new appliance region must reach this list before the node
   starts sending UCANs. Removed/retired regions no longer receive resolution.
4. In the designated test stage, verify an allowed Ingot request succeeds and a
   disallowed issuer causes no outbound request and receives the same rejection
   regardless of target reachability. Include redirects. Then promote the
   tested image digest and reviewed configuration through the normal workflow.

This branch changes source configuration only. No image digest was bumped and
no plan/apply, live configuration inspection or deployment was performed.

## Offline checks

`make check` now runs the provider-free native plan tests after formatting.
They cover stage-specific exact identities, deterministic deduplication, empty
deny-all, and rejection of comma or wildcard injection. The module contains no
providers or resources, so these tests do not access AWS or create resources.
The ordinary stage plans and designated-stage runtime checks remain required.
