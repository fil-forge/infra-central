output "provision_repository_url" {
  description = "What `make publish` pushes to. Stages derive the same URL from their own account and region rather than reading it here, so nothing consumes this output."
  value       = aws_ecr_repository.provision.repository_url
}
