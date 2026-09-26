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

output "ecr_repository_url" {
  description = "ECR repository the transform image is pushed to."
  value       = aws_ecr_repository.transform.repository_url
}

output "transform_function_name" {
  description = "Transform Lambda function name."
  value       = aws_lambda_function.transform.function_name
}

output "transform_log_group" {
  description = "CloudWatch log group for the transform function."
  value       = aws_cloudwatch_log_group.transform.name
}

output "transform_schedule_name" {
  description = "EventBridge schedule driving the transform function."
  value       = aws_scheduler_schedule.transform_hourly.name
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

    # Run the transform once (reads the new raw files, replaces the warehouse).
    # The CLI gives up waiting after 60 s by default and then invokes AGAIN, which
    # would start a second, overlapping run; so wait longer than the function may run:
    aws lambda invoke --function-name ${aws_lambda_function.transform.function_name} --cli-read-timeout ${var.transform_timeout_seconds + 10} --profile ${var.aws_profile} --region ${var.aws_region} response.json; cat response.json

    # The warehouse, and the transform's logs:
    aws s3api head-object --bucket ${aws_s3_bucket.raw.bucket} --key warehouse/eskom_data.duckdb --profile ${var.aws_profile} --region ${var.aws_region}
    aws logs tail ${aws_cloudwatch_log_group.transform.name} --since 15m --profile ${var.aws_profile} --region ${var.aws_region}
  EOT
}
