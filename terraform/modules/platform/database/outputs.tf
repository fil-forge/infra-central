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

output "master_secret_kms_key_arn" {
  description = "Key encrypting the master secret. Named in the provision Lambda's kms:Decrypt statement."
  value       = data.aws_kms_key.master_secret.arn
}
