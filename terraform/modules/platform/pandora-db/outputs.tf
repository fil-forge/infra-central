output "address" {
  value = module.aurora.address
}

output "port" {
  value = module.aurora.port
}

output "master_secret_arn" {
  value = module.aurora.master_secret_arn
}

output "master_secret_kms_key_arn" {
  value = module.aurora.master_secret_kms_key_arn
}
