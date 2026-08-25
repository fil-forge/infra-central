# Non-secret per-stage configuration. Every secret lives in SSM and is minted
# by the provision Lambda, so this file is safe to commit.

# Production has its own account and its own delegated zone, so it needs no
# stage label: services answer at <service>.forge.fil.one.
zone_name       = "forge.fil.one"
hostname_suffix = "forge.fil.one"

# Where appliances serve S3. An appliance's Ingot identity is
# did:web:<region>.<this>, so renaming it changes every appliance's identity.
content_hostname_suffix = "s3.filonecontent.com"

# Pinned by digest rather than tag, so the image can never move underneath a
# deploy. `make publish` prints the line to paste here.
#
# The sentinel is deliberate: a syntactically valid digest would read as a real
# pin and fail late, while this one fails the plan against the provision
# module's validation, which names the command to run.
provision_image_digest = "REPLACE_ME"

# Filecoin mainnet.
#
# The contract addresses are placeholders. smelt only ever configured
# Calibration, so the mainnet deployment addresses have to come from the
# contracts team before the first prod apply. Leaving them obviously wrong is
# deliberate: a plausible but incorrect address would fail at transaction time
# rather than at review time.
chain = {
  rpc_url  = "https://api.node.glif.io/rpc/v1"
  chain_id = 314

  contracts = {
    fwss                      = "REPLACE_ME"
    filecoin_pay              = "REPLACE_ME"
    service_provider_registry = "REPLACE_ME"
    usdfc_token               = "REPLACE_ME"
  }
}
