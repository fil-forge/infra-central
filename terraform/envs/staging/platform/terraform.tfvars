# Non-secret per-stage configuration. Every secret in this project lives in SSM
# and is minted by the provision Lambda, so this file is safe to commit.
#
# provision_image_digest is absent here on purpose. It lives in
# image.auto.tfvars, where a promotion copies the digest already deployed to
# dev; both stages use the same ECR repository.

# The shared staging zones are delegated to Route53 in the sandbox account.
zone_name = "staging.fil-forge.com"

# Service labels follow the Forge identity RFC (upload, auth, revoke, signer,
# delegator and indexer). Ingot uses the parallel filonecontent.com namespace.
hostname_suffix       = "staging.fil-forge.com"
ingot_hostname_suffix = "staging.filonecontent.com"

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

# Appliance region labels. Adding one here creates the transit key its node's
# OpenBao seals against; moving it to the retired list destroys that key and
# revokes the node's unseal token. A retired label stays in the second list, and
# docs/appliance-onboarding.md is the procedure for both.
#
# eu-central-3 is the virtual S3 region label of the staging FilOne Appliance.
appliance_regions         = ["eu-central-3"]
retired_appliance_regions = []
