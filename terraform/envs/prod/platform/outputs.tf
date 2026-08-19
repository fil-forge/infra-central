# Re-exported wholesale so the apps root can read them through
# terraform_remote_state.

output "platform" {
  value = {
    stage                     = module.platform.stage
    hostname_suffix           = module.platform.hostname_suffix
    cluster_arn               = module.platform.cluster_arn
    vpc_id                    = module.platform.vpc_id
    private_subnet_ids        = module.platform.private_subnet_ids
    service_security_group_id = module.platform.service_security_group_id
    namespace_id              = module.platform.namespace_id
    namespace_name            = module.platform.namespace_name
    listener_arn              = module.platform.listener_arn
    alb_dns_name              = module.platform.alb_dns_name
    alb_zone_id               = module.platform.alb_zone_id
    route53_zone_id           = module.platform.route53_zone_id
    bucket_names              = module.platform.bucket_names
    bucket_arns               = module.platform.bucket_arns
    allow_list_table_name     = module.platform.allow_list_table_name
    provider_info_table_name  = module.platform.provider_info_table_name
    dynamodb_table_arns       = module.platform.dynamodb_table_arns
    openbao_internal_address  = module.platform.openbao_internal_address
    chain                     = module.platform.chain
  }
}

output "service_dids" {
  description = "did:key per service, stable across restarts."
  value       = module.platform.service_dids
}

output "wallet_addresses" {
  description = "Fund these with FIL, and the payer with USDFC."
  value       = module.platform.wallet_addresses
}

output "created_parameters" {
  description = "Empty on a steady-state apply. A non-empty list after the first apply means something was regenerated; check it before assuming a wallet is intact."
  value       = module.platform.created_parameters
}

output "openbao_public_url" {
  value = module.platform.openbao_public_url
}
