output "bucket_name" {
  description = "Passed to the github-actions-iam module, which grants the CI roles access to this bucket and nothing else."
  value       = aws_s3_bucket.this.id
}

output "bucket_arn" {
  value = aws_s3_bucket.this.arn
}
