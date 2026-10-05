# Non-secret per-stage configuration. Every secret lives in SSM and is minted
# by the provision Lambda, so this file is safe to commit.

# Production has its own account and its own delegated zones, so it needs no
# stage label. Service and Ingot names follow the Forge identity RFC. There is
# no zone_name: each service name is a Route53 zone of its own; see main.tf.
hostname_suffix       = "fil-forge.com"
ingot_hostname_suffix = "filonecontent.com"

# Pinned by digest rather than tag, so the image can never move underneath a
# deploy. `make publish` prints the line to paste here.
#
# The sentinel is deliberate: a syntactically valid digest would read as a real
# pin and fail late, while this one fails the plan against the provision
# module's validation, which names the command to run.
provision_image_digest = "REPLACE_ME"

# Filecoin mainnet.
#
# Public on-chain addresses. fwss, filecoin_pay and service_provider_registry
# are the chain 314 entries in fil-forge/filecoin-services; usdfc_token is the
# token FWSS on mainnet is constructed with. A contract redeployment arrives as
# a reviewable diff here; FIL-1277 will replace FWSS with Forge's own fork.
#   https://github.com/fil-forge/filecoin-services/blob/main/service_contracts/deployments.json
chain = {
  rpc_url  = "https://api.node.glif.io/rpc/v1"
  chain_id = 314

  contracts = {
    fwss                      = "0x56e53c5e7F27504b810494cc3b88b2aa0645a839"
    filecoin_pay              = "0x23b1e018F08BB982348b15a86ee926eEBf7F4DAa"
    service_provider_registry = "0xf55dDbf63F1b55c3F1D4FA7e339a68AB7b64A5eB"
    usdfc_token               = "0x80B98d3aa09ffff255c3ba4A241111Ff1262F045"
  }
}
