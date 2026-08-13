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
