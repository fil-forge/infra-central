# Non-secret per-stage configuration. Every secret lives in SSM and is minted
# by the provision Lambda, so this file is safe to commit.

# Production has its own account and its own delegated zone, so it needs no
# stage label: services answer at <service>.forge.fil.one.
zone_name       = "forge.fil.one"
hostname_suffix = "forge.fil.one"

# Pinned by digest rather than tag, so the image can never move underneath a
# deploy. `make publish` prints the line to paste here.
provision_image_digest = "sha256:0000000000000000000000000000000000000000000000000000000000000000"

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
