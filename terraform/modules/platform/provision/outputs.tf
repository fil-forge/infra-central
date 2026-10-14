# Callers invoke the function through this name, so it waits for the role
# policy too. Otherwise an apply that adds a grant and a phase that needs it
# could invoke the phase first and fail with AccessDenied.
output "function_name" {
  value      = aws_lambda_function.this.function_name
  depends_on = [aws_iam_role_policy.this]
}

output "function_arn" {
  value = aws_lambda_function.this.arn
}

output "role_arn" {
  value = aws_iam_role.this.arn
}
