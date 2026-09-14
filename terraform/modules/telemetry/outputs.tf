output "log_firehose_arns" {
  description = "Stage to the ARN of its log Firehose. For operator visibility; stage roots derive the same ARN from their own stage, account and region rather than reading it here."
  value       = { for stage, stream in aws_kinesis_firehose_delivery_stream.logs : stage => stream.arn }
}

output "metric_stream_name" {
  description = "What `aws cloudwatch get-metric-stream --name` takes to check the stream is running."
  value       = aws_cloudwatch_metric_stream.this.name
}

output "backup_bucket_name" {
  description = "Where a Firehose writes a batch Grafana refused. Empty is the healthy state."
  value       = aws_s3_bucket.backup.bucket
}
