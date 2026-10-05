# Values that more than one root module has to agree on.
#
# Root modules cannot share a variable, and a literal copied into several of
# them drifts. This module creates nothing, so any root can instantiate it for
# the cost of a `module` block.

output "nonprod_account_id" {
  description = "filone-sandbox, holding every non-prod stage and the bootstrap workspaces that feed them."
  value       = "654654381893"
}

output "prod_account_id" {
  description = "filone-production, holding the prod stage and its bootstrap workspaces."
  value       = "811430801166"
}

output "provision_repository_name" {
  description = "ECR repository holding the provision Lambda image. A stage derives its image URL from this name plus its own account and region, so the URL cannot disagree with the repository the bootstrap workspace created."
  value       = "forge-central/provision"
}

output "public_hostname_labels" {
  description = "First label of every public hostname a stage serves, by service: <label>.<hostname_suffix>. The apps module names its services from it, the ingress module certifies the same names, and the prod account bootstrap creates one Route53 zone per label, so a new public service cannot be missed by any of them."
  value = {
    sprue           = "upload"
    hilt            = "auth"
    swarf           = "revoke"
    delegator       = "delegator"
    signing-service = "signer"
    plc             = "plc"
    openbao         = "ssm"
  }
}

# The stages each account holds. Read by both bootstrap roots in an account:
# the account root grants the CI roles state access by stage prefix, and the
# regional root creates one log Firehose per stage. A stage listed in one and
# not the other either cannot plan or ships nothing to Grafana, so there is one
# list. The CI workflow's matrix names the stages a third time in YAML, which
# cannot read a module output; that copy is the one to keep in step by hand.
output "nonprod_stages" {
  description = "Stages deployed into the non-prod account."
  value       = ["dev", "staging"]
}

output "prod_stages" {
  description = "Stages deployed into the prod account."
  value       = ["prod"]
}

output "prod_aurora_key_alias" {
  description = "Alias of the KMS key encrypting the prod Aurora cluster. The prod regional bootstrap creates it and the prod platform root looks it up, so the key outlives any destroy of the platform root."
  value       = "alias/fc-prod-aurora"
}

output "prod_openbao_seal_key_alias" {
  description = "Alias of the KMS key prod OpenBao seals its storage with. The prod regional bootstrap creates it and the prod platform root looks it up, so the key outlives any destroy of the platform root."
  value       = "alias/fc-prod-openbao-seal"
}
