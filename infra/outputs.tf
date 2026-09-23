# Values printed after apply — the handles used to verify and operate the stack.

output "raw_bucket" {
  description = "S3 bucket holding the raw landing zone."
  value       = aws_s3_bucket.raw.bucket
}

output "function_name" {
  description = "Extract Lambda function name."
  value       = aws_lambda_function.extract.function_name
}

output "log_group" {
  description = "CloudWatch log group for the extract function."
  value       = aws_cloudwatch_log_group.extract.name
}

output "schedule_name" {
  description = "EventBridge schedule driving the function."
  value       = aws_scheduler_schedule.hourly.name
}

output "verify_commands" {
  description = "Copy-paste checks: invoke once, then list what landed."
  value       = <<-EOT
    # Invoke once (costs 2 EskomSePush API calls):
    aws lambda invoke --function-name ${aws_lambda_function.extract.function_name} --profile ${var.aws_profile} --region ${var.aws_region} response.json; cat response.json

    # What landed in the bucket:
    aws s3 ls s3://${aws_s3_bucket.raw.bucket}/raw/ --recursive --profile ${var.aws_profile}

    # Recent logs:
    aws logs tail ${aws_cloudwatch_log_group.extract.name} --since 15m --profile ${var.aws_profile} --region ${var.aws_region}
  EOT
}
