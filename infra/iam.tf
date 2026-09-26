# Identities for the workload.
#
# One role per component, because in AWS every component authenticates as itself:
#   * each Lambda's execution role — what that function's code may do
#   * the state machine's role     — invoke those two functions, publish alerts
#   * the scheduler's role         — start the state machine, nothing else
#
# Every resource below is addressed by reference (aws_s3_bucket.raw.arn) rather
# than a typed-out ARN, so a name can never drift out of sync with a policy.

# ── Lambda execution role ─────────────────────────────────────────────────────

# A trust policy answers "who may assume this role?" — here, the Lambda service
# itself. It is separate from the permissions policy, which answers "and what
# may they then do?".
data "aws_iam_policy_document" "extract_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "extract" {
  name               = "${var.project_name}-extract"
  description        = "Execution role for the extract Lambda: write raw objects, read one parameter, write its own logs."
  assume_role_policy = data.aws_iam_policy_document.extract_assume_role.json
}

# The SSM parameter is created out of band (its value must never enter state),
# so its ARN is constructed rather than looked up. A data source would pull the
# secret value into the state file.
locals {
  api_key_parameter_arn = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.api_key_parameter_name}"
}

# A SecureString is encrypted with the AWS-managed key aws/ssm. That key's own
# policy (written by AWS) already lets any principal in this account decrypt
# through SSM, so the kms:Decrypt statement below is not strictly required; it
# is kept so the dependency on KMS is visible here rather than only in a policy
# AWS manages. It would be required for a customer-managed key. The key is
# created by AWS the first time a SecureString is stored — which is why the
# parameter must exist before the first plan.
data "aws_kms_alias" "ssm" {
  name = "alias/aws/ssm"
}

data "aws_iam_policy_document" "extract" {
  statement {
    sid       = "WriteRawObjectsOnly"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.raw.arn}/raw/*"]
  }

  # Scoped to this one parameter. A wildcard here would silently extend to every
  # secret added to the account in future — see ADR 0003 and the README.
  statement {
    sid       = "ReadApiKeyParameterOnly"
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = [local.api_key_parameter_arn]
  }

  statement {
    sid       = "DecryptApiKeyParameter"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [data.aws_kms_alias.ssm.target_key_arn]
  }

  # Only its own log group. Note that CreateLogGroup is absent: Terraform
  # creates the group, so the function does not need permission to make one.
  statement {
    sid       = "WriteOwnLogsOnly"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.extract.arn}:*"]
  }
}

resource "aws_iam_role_policy" "extract" {
  name   = "${var.project_name}-extract"
  role   = aws_iam_role.extract.id
  policy = data.aws_iam_policy_document.extract.json
}

# ── Transform execution role ──────────────────────────────────────────────────

data "aws_iam_policy_document" "transform_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "transform" {
  name               = local.transform_function_name
  description        = "Execution role for the transform Lambda: list and read raw/, read and replace the warehouse, write its own logs."
  assume_role_policy = data.aws_iam_policy_document.transform_assume_role.json
}

data "aws_iam_policy_document" "transform" {
  # DuckDB expands raw/**/*.json by listing the raw/ prefix. warehouse/ is
  # listable for a less obvious reason: S3 reports a missing object as "not
  # found" only to a caller that may list that key's prefix, and as "access
  # denied" to anyone else. The handler recognises a first run (no warehouse
  # yet) by "not found". Tested 2026-09-25; see docs/PHASE2_PLAN.md.
  statement {
    sid       = "ListRawAndWarehousePrefixesOnly"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.raw.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["raw/*", "warehouse/*"]
    }
  }

  statement {
    sid     = "ReadRawAndWarehouse"
    effect  = "Allow"
    actions = ["s3:GetObject"]
    resources = [
      "${aws_s3_bucket.raw.arn}/raw/*",
      "${aws_s3_bucket.raw.arn}/warehouse/*",
    ]
  }

  # Writes go to the warehouse only, so the transform can never alter the raw
  # history it reads. The upload's If-Match / If-None-Match conditions need no
  # permission of their own.
  statement {
    sid       = "ReplaceWarehouseOnly"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.raw.arn}/warehouse/*"]
  }

  statement {
    sid       = "WriteOwnLogsOnly"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.transform.arn}:*"]
  }
}

resource "aws_iam_role_policy" "transform" {
  name   = local.transform_function_name
  role   = aws_iam_role.transform.id
  policy = data.aws_iam_policy_document.transform.json
}

# ── Step Functions role (Phase 3) ─────────────────────────────────────────────

data "aws_iam_policy_document" "pipeline_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }

    # Step Functions assumes the role on behalf of one state machine and says
    # which. These conditions accept only this one, in this account, so no other
    # state machine - here or in another account - can be given this role and
    # act with its permissions (the "confused deputy" problem). The ARN is
    # written out in orchestration.tf, because referring to the state machine
    # from its own role's policy would be a cycle.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [local.pipeline_arn]
    }
  }
}

resource "aws_iam_role" "pipeline" {
  name               = local.pipeline_name
  description        = "Role of the pipeline state machine: invoke the extract and transform functions, publish failure alerts."
  assume_role_policy = data.aws_iam_policy_document.pipeline_assume_role.json
}

data "aws_iam_policy_document" "pipeline" {
  # The unqualified ARNs: the state machine always invokes the latest code.
  statement {
    sid     = "InvokePipelineFunctionsOnly"
    effect  = "Allow"
    actions = ["lambda:InvokeFunction"]
    resources = [
      aws_lambda_function.extract.arn,
      aws_lambda_function.transform.arn,
    ]
  }

  statement {
    sid       = "PublishAlertsOnly"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
  }
}

resource "aws_iam_role_policy" "pipeline" {
  name   = local.pipeline_name
  role   = aws_iam_role.pipeline.id
  policy = data.aws_iam_policy_document.pipeline.json
}

# ── EventBridge Scheduler role ────────────────────────────────────────────────

data "aws_iam_policy_document" "scheduler_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name               = "${var.project_name}-scheduler"
  description        = "Lets EventBridge Scheduler start the pipeline state machine, and nothing else."
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume_role.json
}

# Since Phase 3 the scheduler starts the state machine and never invokes a
# function itself, so it has no Lambda permission at all.
data "aws_iam_policy_document" "scheduler" {
  statement {
    sid       = "StartPipelineOnly"
    effect    = "Allow"
    actions   = ["states:StartExecution"]
    resources = [aws_sfn_state_machine.pipeline.arn]
  }
}

resource "aws_iam_role_policy" "scheduler" {
  name   = "${var.project_name}-scheduler"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler.json
}
