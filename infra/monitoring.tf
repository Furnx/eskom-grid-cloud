# How a failure reaches a human (Phase 3, ADR 0010).
#
# One topic, two publishers:
#   * the state machine's failure branch (orchestration.tf) - the detailed
#     message: which step failed, the error and its cause, a link to the run;
#   * the alarm below - a backstop for a failure the branch cannot report,
#     namely one inside the branch itself.
# Most failures therefore send two emails. An alarm email that arrives alone
# means the branch failed too: look at the execution in the console.
#
# First deployment only: create the topic and subscription on their own, and
# confirm the subscription, before the state machine exists (README, Deploy):
#   terraform apply "-target=aws_sns_topic_subscription.alert_email"

resource "aws_sns_topic" "alerts" {
  name = "${var.project_name}-alerts"

  # Deliberately not encrypted with KMS. CloudWatch alarms cannot publish to a
  # topic encrypted with the AWS-managed key (aws/sns), and a customer-managed
  # key costs $1 a month (ADR 0003). The messages carry no secrets: the API key
  # travels in a request header, never in an error message.
}

# Created as "pending confirmation": AWS emails a link, and nothing is delivered
# until it is clicked. Terraform cannot click it, and cannot delete a
# subscription that was never confirmed; AWS removes those after three days.
resource "aws_sns_topic_subscription" "alert_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_metric_alarm" "pipeline_failed" {
  alarm_name        = "${local.pipeline_name}-failed"
  alarm_description = "A run of the ${local.pipeline_name} state machine failed. The failure branch normally sends the details in a separate email; if this one came alone, the branch itself failed. See the execution history."

  namespace   = "AWS/States"
  metric_name = "ExecutionsFailed"
  dimensions = {
    StateMachineArn = aws_sfn_state_machine.pipeline.arn
  }

  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1

  # Step Functions publishes this metric only when an execution fails, so most
  # periods have no data at all. Here, no data means nothing failed.
  treat_missing_data = "notBreaching"

  # No ok_actions: the alarm returns to OK five minutes after a failure, which
  # says nothing about whether the next run succeeded. An email would mislead.
  alarm_actions = [aws_sns_topic.alerts.arn]
}
