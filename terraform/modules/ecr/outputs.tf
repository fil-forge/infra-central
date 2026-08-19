output "provision_repository_url" {
  description = "What `make publish` pushes to. Re-exported by the bootstrap root modules for operator visibility; stages derive the same URL from their own account and region rather than reading it here."
  value       = aws_ecr_repository.provision.repository_url
}
