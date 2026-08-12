output "provision_repository_url" {
  description = "Pass to each stage in this region as provision_image_repository_url."
  value       = aws_ecr_repository.provision.repository_url
}
