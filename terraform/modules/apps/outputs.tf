output "service_urls" {
  description = "Public URL per service. plc is absent because it has no public hostname."
  value = {
    sprue             = module.sprue.public_url
    hilt              = module.hilt.public_url
    swarf             = module.swarf.public_url
    delegator         = module.delegator.public_url
    "signing-service" = module.signing_service.public_url
  }
}

output "service_dids" {
  description = "The did:web each service was given. sprue, hilt, swarf and the delegator publish a document at /.well-known/did.json; piri-signing-service does not, so its DID resolves nowhere. Nothing addresses it by DID today."
  value       = local.did
}

output "plc_internal_url" {
  value = local.plc_directory
}

output "log_groups" {
  value = {
    sprue             = module.sprue.log_group_name
    hilt              = module.hilt.log_group_name
    swarf             = module.swarf.log_group_name
    delegator         = module.delegator.log_group_name
    "signing-service" = module.signing_service.log_group_name
    plc               = module.plc.log_group_name
  }
}
