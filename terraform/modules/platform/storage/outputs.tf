output "bucket_names" {
  description = "Logical bucket name to real bucket name, e.g. agent-message => fc-dev-agent-message-123456789012."
  value       = { for key, bucket in aws_s3_bucket.this : key => bucket.id }
}

output "bucket_arns" {
  value = [for bucket in aws_s3_bucket.this : bucket.arn]
}

output "allow_list_table_name" {
  value = aws_dynamodb_table.allow_list.name
}

output "allow_list_table_arn" {
  value = aws_dynamodb_table.allow_list.arn
}

output "provider_info_table_name" {
  value = aws_dynamodb_table.provider_info.name
}

output "table_arns" {
  value = [aws_dynamodb_table.allow_list.arn, aws_dynamodb_table.provider_info.arn]
}
