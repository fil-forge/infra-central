locals {
  seed = jsondecode(aws_lambda_invocation.seed.result)
}

# --- Consumed by the apps workspace through tfe_outputs ---

output "stage" {
  value = var.stage
}

output "hostname_suffix" {
  value = var.hostname_suffix
}

output "cluster_arn" {
  value = aws_ecs_cluster.this.arn
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "private_subnet_ids" {
  value = module.network.private_subnet_ids
}

output "service_security_group_id" {
  value = module.network.service_security_group_id
}

output "namespace_id" {
  value = module.network.namespace_id
}

output "namespace_name" {
  value = module.network.namespace_name
}

output "listener_arn" {
  value = module.ingress.listener_arn
}

# Still named for the load balancer, because that is the name the apps
# workspace reads them by through tfe_outputs. On a stage running Global
# Accelerator they carry the accelerator instead, and every service alias
# follows without the apps module knowing the difference.
output "alb_dns_name" {
  value = module.ingress.public_dns_name
}

output "alb_zone_id" {
  value = module.ingress.public_zone_id
}

output "route53_zone_id" {
  value = module.ingress.route53_zone_id
}

output "bucket_names" {
  value = module.storage.bucket_names
}

output "bucket_arns" {
  value = module.storage.bucket_arns
}

output "allow_list_table_name" {
  value = module.storage.allow_list_table_name
}

output "provider_info_table_name" {
  value = module.storage.provider_info_table_name
}

output "dynamodb_table_arns" {
  value = module.storage.table_arns
}

output "chain" {
  description = "Consumed by the apps workspace so chain configuration lives in one place per stage."
  value       = var.chain
}

output "openbao_internal_address" {
  value = module.openbao.internal_address
}

output "openbao_public_url" {
  value = module.openbao.public_url
}

# --- Public material returned by the provision Lambda ---

output "service_dids" {
  description = "Service name to did:key. Stable across task restarts, which is the point of injecting identity keys rather than letting services generate them."
  value       = try(local.seed.dids, {})
}

output "wallet_addresses" {
  description = "Wallet name to EIP-55 address. These are the accounts to fund with FIL — tFIL on Calibration — and USDFC."
  value       = try(local.seed.addresses, {})
}

output "databases" {
  value = try(local.seed.databases, [])
}

output "created_parameters" {
  description = "Parameters minted by the most recent apply. Empty on a steady-state apply, which is how you confirm nothing was regenerated."
  value       = try(local.seed.created, [])
}

output "openbao_initialised" {
  value = try(jsondecode(aws_lambda_invocation.vault.result).initialised, false)
}
