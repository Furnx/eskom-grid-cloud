# The trigger and the orchestration that replace Dagster's daemon and job
# (ADR 0002): every hour, EventBridge Scheduler starts one execution of a Step
# Functions state machine, which runs extract and then transform.
#
#   Extract ──ok──▶ Transform ──ok──▶ succeeded
#      │ error          │ error
#      └───────┬────────┘
#              ▼
#      NotifyFailure   email: which step, the error, its cause, a link to the run
#              ▼
#      RunFailed       the execution ends FAILED, with the step's own error name
#
# Four states: ADR 0003 allows five, to stay within the 4,000 free state
# transitions a month.

locals {
  pipeline_name = "${var.project_name}-pipeline"

  # Written out rather than read from the state machine: the trust policy of
  # its role names it (iam.tf), and the state machine depends on that role.
  pipeline_arn = "arn:aws:states:${var.aws_region}:${data.aws_caller_identity.current.account_id}:stateMachine:${local.pipeline_name}"

  # The alert links to the failed run here; the execution's ARN is appended.
  console_executions_url = "https://${var.aws_region}.console.aws.amazon.com/states/home?region=${var.aws_region}#/v2/executions/details/"

  # The only retries (ADR 0009): failures AROUND a function - the invoke
  # failed, was throttled, or hit a fault inside Lambda - which usually happen
  # before the handler runs, so repeating them spends no API quota. Anything
  # the handler itself raises goes straight to the failure branch; the next
  # hourly run is its retry.
  retry_lambda_service_errors = [{
    ErrorEquals = [
      "Lambda.ServiceException",
      "Lambda.AWSLambdaException",
      "Lambda.SdkClientException",
      "Lambda.TooManyRequestsException",
    ]
    IntervalSeconds = 2
    MaxAttempts     = 3
    BackoffRate     = 2
  }]
}

resource "aws_sfn_state_machine" "pipeline" {
  name     = local.pipeline_name
  role_arn = aws_iam_role.pipeline.arn

  # STANDARD, not EXPRESS: Express workflows have no free allowance and stop
  # after five minutes, and the two functions may take six between them.
  type = "STANDARD"

  # Amazon States Language. Strings wrapped in {% %} are JSONata expressions,
  # evaluated per execution: $states.input is what the state received,
  # $states.result what the call returned, $states.errorOutput the error that
  # a Catch caught ({Error, Cause}). An expression whose result is empty fails
  # the state, so a value that may be missing gets a fallback: `x ? x : '...'`
  # covers both a missing x and a null one (an error without a cause arrives
  # with Cause null, which $exists() would accept).
  definition = jsonencode({
    Comment       = "Every hour: extract, then transform. A failure is emailed, then the run is marked failed."
    QueryLanguage = "JSONata"
    StartAt       = "Extract"
    States = {
      Extract = {
        Type = "Task"
        # Invokes the function synchronously and waits for its answer, so a
        # failed run comes back here. Lambda's own retries of asynchronous
        # invocations never apply.
        Resource = "arn:aws:states:::lambda:invoke"
        Arguments = {
          FunctionName = aws_lambda_function.extract.arn
          Payload      = {}
        }
        # The handler's summary, without the invoke's metadata around it.
        Output = { extract = "{% $states.result.Payload %}" }
        Retry  = local.retry_lambda_service_errors
        Catch = [{
          ErrorEquals = ["States.ALL"]
          Output      = { step = "Extract", error = "{% $states.errorOutput %}" }
          Next        = "NotifyFailure"
        }]
        Next = "Transform"
      }

      Transform = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Arguments = {
          FunctionName = aws_lambda_function.transform.arn
          Payload      = {}
        }
        # The execution's output: both summaries, each naming the application
        # version that produced it.
        Output = "{% $merge([$states.input, {'transform': $states.result.Payload}]) %}"
        Retry  = local.retry_lambda_service_errors
        Catch = [{
          ErrorEquals = ["States.ALL"]
          Output      = { step = "Transform", error = "{% $states.errorOutput %}" }
          Next        = "NotifyFailure"
        }]
        End = true
      }

      NotifyFailure = {
        Type     = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Arguments = {
          TopicArn = aws_sns_topic.alerts.arn
          # SNS allows 100 characters and no line breaks in a subject.
          Subject = "{% $substring('eskom-grid: ' & $states.input.step & ' failed (' & $states.input.error.Error & ')', 0, 100) %}"
          Message = trimspace(<<-EOT
            {% $join([
              'An eskom-grid pipeline run failed.',
              '',
              'Step:  ' & $states.input.step,
              'Error: ' & $states.input.error.Error,
              'Cause: ' & ($states.input.error.Cause ? $states.input.error.Cause : '(none given)'),
              '',
              'Run:     ${local.console_executions_url}' & $states.context.Execution.Id,
              'Started: ' & $states.context.Execution.StartTime & ' (UTC)',
              '',
              'Only failures of Lambda itself are retried (ADR 0009). The next scheduled run tries again.'
            ], '\n') %}
          EOT
          )
        }
        # Passes the failure on, not the publish receipt: RunFailed reports it.
        Output = "{% $states.input %}"
        Next   = "RunFailed"
      }

      # Ends the execution as FAILED, so its status tells the truth and the
      # alarm (monitoring.tf) sees it, with the step's error as its own.
      RunFailed = {
        Type  = "Fail"
        Error = "{% $states.input.error.Error %}"
        Cause = "{% $states.input.step & ': ' & ($states.input.error.Cause ? $states.input.error.Cause : '(none given)') %}"
      }
    }
  })

  # The role must hold its permissions before the first execution starts.
  depends_on = [aws_iam_role_policy.pipeline]
}

resource "aws_scheduler_schedule" "hourly" {
  name        = "${var.project_name}-hourly"
  description = "Starts the pipeline state machine (extract, then transform) on the hour, every hour."

  # OFF means fire at the exact time rather than within a tolerance window.
  # A window would let AWS spread invocations, which is useful at scale and
  # unhelpful when you are watching for an object to appear on the hour.
  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = var.schedule_expression
  schedule_expression_timezone = var.schedule_timezone

  target {
    arn      = aws_sfn_state_machine.pipeline.arn
    role_arn = aws_iam_role.scheduler.arn

    # These retries cover only failing to START an execution (throttling, a
    # service error). Nothing has run then, so trying again costs no API
    # quota, while giving up would lose the hour without an alert: neither the
    # failure branch nor the alarm can see an execution that never began.
    # Retries of the steps themselves belong to the state machine (ADR 0009).
    retry_policy {
      maximum_retry_attempts       = 3
      maximum_event_age_in_seconds = 900
    }
  }
}
