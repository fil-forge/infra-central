output "bucket_names" {
  description = "Logical bucket name to real bucket name, e.g. agent-message => fc-dev-agent-message-123456789012."
  value       = { for key, bucket in aws_s3_bucket.this : key => bucket.id }
}

output "bucket_arns" {
  value = [for bucket in aws_s3_bucket.this : bucket.arn]
}
