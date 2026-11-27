# Non-secret per-stage configuration. Every secret in this project lives in SSM
# and is minted by the provision Lambda, so this file is safe to commit.
#
# provision_image_digest is absent here on purpose: `make publish` writes it to
# image.auto.tfvars, so iterating on the Lambda never means editing this file by
# hand. Prod pins its digest in its own terraform.tfvars, copied from dev when a
# change is promoted.

# The dev zone is delegated once by the DNS project. Each ephemeral stage gets
# a label beneath it; this long-lived environment uses the RFC's `latest` label.
zone_name = "dev.fil-forge.com"

# Service labels follow the Forge identity RFC (upload, auth, revoke, signer,
# delegator and indexer). Ingot uses the parallel filonecontent.com namespace.
hostname_suffix       = "latest.dev.fil-forge.com"
ingot_hostname_suffix = "latest.dev.filonecontent.com"

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
    fwss                      = "0x55325AB46CDAB0FbDef559c810cd6bc95cBFEfFd"
    filecoin_pay              = "0x09a0fDc2723fAd1A7b8e3e00eE5DF73841df55a0"
    service_provider_registry = "0x839e5c9988e4e9977d40708d0094103c0839Ac9D"
    usdfc_token               = "0xb3042734b608a1B16e9e86B374A3f3e389B4cDf0"
  }
}

# The appliances this stage serves: each region label and its node's egress
# IPv4 address. Adding one creates the transit key its node's OpenBao seals
# against, binds the node's unseal token to the address, and makes the
# address the only source the signing service admits for that node, since the
# service signs with the payer key for whoever reaches it. Retiring one moves its
# label to retired_appliance_regions, which destroys the key and revokes the
# token; a retired label stays in that list. docs/appliance-onboarding.md is the
# procedure for both.
#
# us-east-9 is the virtual S3 region label of the dev FilOne Appliance running
# in us-east-2. Its address is the node's Elastic IP, which fil-forge/infra-nodes
# allocates and associates with the instance (terraform/modules/node/main.tf,
# aws_eip.node), so the node also sends from it.
appliances = {
  us-east-9 = "3.16.7.182"
}
retired_appliance_regions = []
