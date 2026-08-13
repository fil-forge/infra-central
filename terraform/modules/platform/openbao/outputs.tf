output "internal_address" {
  description = "How hilt and the provision Lambda reach OpenBao, inside the VPC and without TLS termination in the way."
  value       = "http://${module.service.internal_hostname}:${var.port}"
}

output "public_url" {
  description = "Where regional appliances authenticate at boot."
  value       = module.service.public_url
}

output "task_role_arn" {
  value = module.service.task_role_arn
}
