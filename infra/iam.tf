# Identities for the workload.
#
# Two separate roles, because in AWS every component authenticates as itself:
#   * the Lambda's execution role  — what the function's code may do
#   * the scheduler's role         — permission to invoke that one function
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

# A SecureString is encrypted with the AWS-managed key aws/ssm, so reading it
# needs kms:Decrypt on that key in addition to ssm:GetParameter. The key is
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
  description        = "Lets EventBridge Scheduler invoke the extract Lambda, and nothing else."
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume_role.json
}

data "aws_iam_policy_document" "scheduler" {
  statement {
    sid       = "InvokeExtractFunctionOnly"
    effect    = "Allow"
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.extract.arn]
  }
}

resource "aws_iam_role_policy" "scheduler" {
  name   = "${var.project_name}-scheduler"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler.json
}
