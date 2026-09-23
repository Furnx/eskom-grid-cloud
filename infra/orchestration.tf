# The trigger: the managed cron that replaces Dagster's daemon (ADR 0002).
#
# In Phase 3 this target changes from the Lambda to a Step Functions state
# machine, so that extract and transform run in order with independent retries.

resource "aws_scheduler_schedule" "hourly" {
  name        = "${var.project_name}-hourly"
  description = "Invokes the extract Lambda on the hour, every hour."

  # OFF means fire at the exact time rather than within a tolerance window.
  # A window would let AWS spread invocations, which is useful at scale and
  # unhelpful when you are watching for an object to appear on the hour.
  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = var.schedule_expression
  schedule_expression_timezone = var.schedule_timezone

  target {
    arn      = aws_lambda_function.extract.arn
    role_arn = aws_iam_role.scheduler.arn

    # One attempt per tick. A failed run means either the API is down or the
    # quota is exhausted; retrying immediately would spend requests that the
    # next hourly tick can use instead. Phase 3 moves retry policy into the
    # state machine, where it can differ per failure type.
    retry_policy {
      maximum_retry_attempts = 0
    }
  }
}
