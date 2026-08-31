output "task_role_arn" {
  value = aws_iam_role.task.arn
}

output "execution_role_arn" {
  value = aws_iam_role.execution.arn
}

output "internal_hostname" {
  description = "Private DNS name, for callers inside the VPC. Null when the service is not registered internally."
  value       = var.register_internal ? "${var.service}.${var.namespace_name}" : null
}

output "public_url" {
  description = "Null when the service has no public hostname."
  value       = var.hostname == null ? null : "https://${var.hostname}"
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.this.name
}

output "secret_dir" {
  description = "Where the entrypoint wrapper writes file-borne secrets. Callers point *_KEY_FILE settings at paths under this."
  value       = local.secret_dir
}
