output "ci_plan_role_arn" {
  description = "Role that pull-request workflows assume (named in .github/workflows/plan.yml)."
  value       = aws_iam_role.ci_plan.arn
}

output "state_bucket" {
  description = "Bucket holding Terraform's state. Named literally in both backend blocks, which can't use variables."
  value       = aws_s3_bucket.tfstate.bucket
}
