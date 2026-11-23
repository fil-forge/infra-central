output "trail_name" {
  description = "What `aws cloudtrail get-trail-status --name` takes to check the trail is logging."
  value       = aws_cloudtrail.this.name
}

output "trail_bucket" {
  description = "Where the trail keeps a year of the provision functions' invocations."
  value       = aws_s3_bucket.trail.bucket
}
