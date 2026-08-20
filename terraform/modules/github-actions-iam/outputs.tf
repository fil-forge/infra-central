output "plan_role_arn" {
  description = "Set as the role-to-assume for the plan jobs in .github/workflows/check-and-deploy.yml."
  value       = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  description = "Set as the role-to-assume for the apply jobs in .github/workflows/check-and-deploy.yml."
  value       = aws_iam_role.apply.arn
}
