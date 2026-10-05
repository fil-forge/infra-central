# Non-secret per-stage configuration. Every secret lives in SSM and is minted
# by the provision Lambda, so this file is safe to commit.

# Production has its own account and its own delegated zones, so it needs no
# stage label. Service and Ingot names follow the Forge identity RFC. There is
# no zone_name: each service name is a Route53 zone of its own; see main.tf.
hostname_suffix       = "fil-forge.com"
ingot_hostname_suffix = "filonecontent.com"

# Pinned by digest rather than tag, so the image can never move underneath a
# deploy. `make publish STAGE=prod` prints the line to paste here.
provision_image_digest = "sha256:4c136e973c35168deaca926df4e0f3459c2bda4ed775c5b1ca0b947f837d7fa8"

# Calibration testnet, with the proxy addresses dev and staging use, for the
# first prod stack's test run. Prod moves to mainnet with the Forge contracts
# from FIL-1277; see docs/decisions/2026-10-prod-first-stack.md.
#
# Public on-chain addresses, and a contract redeployment should arrive as a
# reviewable diff. Sources:
#   https://github.com/FilOzone/filecoin-services/releases
#   https://github.com/fil-forge/filecoin-services/blob/main/service_contracts/deployments.json
chain = {
  rpc_url  = "https://api.calibration.node.glif.io/rpc/v1"
  chain_id = 314159

  contracts = {
    fwss                      = "0x0c6875983B20901a7C3c86871f43FdEE77946424"
    filecoin_pay              = "0x09a0fDc2723fAd1A7b8e3e00eE5DF73841df55a0"
    service_provider_registry = "0x839e5c9988e4e9977d40708d0094103c0839Ac9D"
    usdfc_token               = "0xb3042734b608a1B16e9e86B374A3f3e389B4cDf0"
  }
}
