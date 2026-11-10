output "bucket_name" {
  value = aws_s3_bucket.this.id
}

output "bucket_arn" {
  value = aws_s3_bucket.this.arn
}

output "user_prefix" {
  description = "What every region's writer user name starts with. The provision Lambda appends the region label, and its role is granted on this prefix."
  value       = local.user_prefix
}

output "user_names" {
  description = "Region label to writer user name."
  value       = { for region, user in aws_iam_user.writer : region => user.name }
}
