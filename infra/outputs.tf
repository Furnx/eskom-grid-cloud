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
  description = "EventBridge schedule that starts the pipeline every hour."
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

output "state_machine_arn" {
  description = "The pipeline state machine (extract, then transform)."
  value       = aws_sfn_state_machine.pipeline.arn
}

output "alerts_topic_arn" {
  description = "SNS topic that failure alerts are published to."
  value       = aws_sns_topic.alerts.arn
}

output "verify_commands" {
  description = "Copy-paste checks: run the pipeline once, then look at what it did."
  value       = <<-EOT
    # Alerts reach only a confirmed subscription. "PendingConfirmation" means the
    # link in AWS's email has not been clicked yet:
    aws sns list-subscriptions-by-topic --topic-arn ${aws_sns_topic.alerts.arn} --query "Subscriptions[].SubscriptionArn" --output text --profile ${var.aws_profile} --region ${var.aws_region}

    # Run the whole pipeline once, as the schedule does. It costs 2 of the 50
    # daily EskomSePush requests, and must not overlap another run, so first
    # check that nothing is running (no output means nothing is):
    aws stepfunctions list-executions --state-machine-arn ${aws_sfn_state_machine.pipeline.arn} --status-filter RUNNING --query "executions[].name" --output text --profile ${var.aws_profile} --region ${var.aws_region}
    aws stepfunctions start-execution --state-machine-arn ${aws_sfn_state_machine.pipeline.arn} --profile ${var.aws_profile} --region ${var.aws_region}

    # The last five runs and how they ended (each step's input and output is in
    # the console's view of the execution):
    aws stepfunctions list-executions --state-machine-arn ${aws_sfn_state_machine.pipeline.arn} --max-items 5 --query "executions[].[name, status, startDate]" --output table --profile ${var.aws_profile} --region ${var.aws_region}

    # What landed in the bucket, and the warehouse the transform replaced:
    aws s3 ls s3://${aws_s3_bucket.raw.bucket}/raw/ --recursive --profile ${var.aws_profile}
    aws s3api head-object --bucket ${aws_s3_bucket.raw.bucket} --key warehouse/eskom_data.duckdb --profile ${var.aws_profile} --region ${var.aws_region}

    # Recent logs. Each run's first line names the application version:
    aws logs tail ${aws_cloudwatch_log_group.extract.name} --since 15m --profile ${var.aws_profile} --region ${var.aws_region}
    aws logs tail ${aws_cloudwatch_log_group.transform.name} --since 15m --profile ${var.aws_profile} --region ${var.aws_region}

    # Run only the transform (no API cost). This bypasses the state machine: no
    # retries and no alert. The CLI gives up waiting after 60 s by default and
    # then invokes AGAIN, which would start a second, overlapping run; so wait
    # longer than the function may run:
    aws lambda invoke --function-name ${aws_lambda_function.transform.function_name} --cli-read-timeout ${var.transform_timeout_seconds + 10} --profile ${var.aws_profile} --region ${var.aws_region} response.json; cat response.json
  EOT
}
