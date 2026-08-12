# Non-secret per-stage configuration. Every secret in this project lives in SSM
# and is minted by the provision Lambda, so this file is safe to commit.
#
# provision_image_digest is absent here on purpose: `make publish` writes it to
# the gitignored image.auto.tfvars, so iterating on the Lambda never means
# editing a tracked file. Prod pins its digest in this file instead.

# The zone is delegated once, by the DNS project, and holds every non-prod
# stage. Adding a stage writes records into it and needs no change there.
zone_name = "forge-sandbox.fil.one"

# Services answer at <service>.dev.forge-sandbox.fil.one. The stage label lives
# inside the zone, which is what lets one delegation serve dev, staging and any
# future PR-preview stage.
hostname_suffix = "dev.forge-sandbox.fil.one"

# From the repository_url output of the bootstrap workspace for this region.
provision_image_repository_url = "REPLACE_ME.dkr.ecr.us-east-2.amazonaws.com/forge-provision"

# Calibration testnet proxy addresses, carried over from smelt's
# environments/staging/smart-contracts.env. Public on-chain addresses, and a
# contract redeployment should arrive as a reviewable diff.
#
# Owned by this workspace rather than by apps, so the services and the fund
# phase read the same values. Sources:
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
