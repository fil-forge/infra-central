# Passed as one object to every module that owns a log group, so a caller
# cannot hand over the Firehose without the role or the role without the
# Firehose.
#
# Creating a subscription filter sends a test record through the role, and a
# role whose policy has not attached yet fails that with "Could not deliver test
# message to specified Firehose stream", which names neither the role nor the
# policy. The dependency on the policy resource is what makes every consumer
# wait for both. IAM is eventually consistent, so the first apply can still hit
# it once; a re-run of the job is the fix.
output "log_forwarding" {
  value = {
    firehose_arn = local.firehose_arn
    role_arn     = aws_iam_role.this.arn
  }

  depends_on = [aws_iam_role_policy.this]
}
