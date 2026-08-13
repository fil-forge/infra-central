output "address" {
  value = aws_db_instance.this.address
}

output "port" {
  value = aws_db_instance.this.port
}

output "master_secret_arn" {
  description = "Secrets Manager secret RDS manages itself. Read by the provision Lambda; never by Terraform."
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "master_secret_kms_key_id" {
  value = aws_db_instance.this.master_user_secret[0].kms_key_id
}
