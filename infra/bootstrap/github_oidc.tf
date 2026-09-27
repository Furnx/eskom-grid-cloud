# How GitHub Actions signs in to this account, with no stored keys (ADR 0012).
#
# A workflow run asks GitHub for a short-lived token that states, among other
# things, which repository it belongs to and why it runs ("a pull request",
# "a push to main"), signed by GitHub. AWS checks GitHub's signature against the
# identity provider below, then each role's trust policy decides which of those
# statements it accepts. What comes back are credentials that expire within
# the hour.

resource "aws_iam_openid_connect_provider" "github" {
  url = "https://${local.github_token_issuer}"

  # The audience GitHub puts in a token requested for AWS.
  client_id_list = ["sts.amazonaws.com"]

  # No thumbprint_list: for GitHub's issuer, AWS checks the certificate itself.
}

locals {
  github_token_issuer = "token.actions.githubusercontent.com"
}

# ── The plan role: pull requests, read-only ───────────────────────────────────

data "aws_iam_policy_document" "ci_plan_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_token_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Only runs for a pull request in this repository, named the way GitHub
    # names it in tokens (var.github_subject). GitHub gives a pull request
    # from someone's fork read-only permissions, so it can't request a token
    # in the first place.
    condition {
      test     = "StringEquals"
      variable = "${local.github_token_issuer}:sub"
      values   = ["${var.github_subject}:pull_request"]
    }
  }
}

resource "aws_iam_role" "ci_plan" {
  name               = "${var.project_name}-ci-plan"
  description        = "Assumed by GitHub Actions for a pull request's plan: reads everything, changes nothing, never reads parameters."
  assume_role_policy = data.aws_iam_policy_document.ci_plan_trust.json
}

# AWS's ready-made read-only policy (ADR 0012): a plan reads many services, and
# a hand-written list would need growing with every new kind of resource.
resource "aws_iam_role_policy_attachment" "ci_plan_read_only" {
  role       = aws_iam_role.ci_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# ReadOnlyAccess reads more than a plan needs, including SSM parameters, and
# the key they are encrypted with (aws/ssm) lets any principal in the account
# that may read a parameter decrypt it: that would include the API key. An
# explicit deny always beats an allow, so this closes that door. Terraform
# never reads the parameter; it only builds its ARN (infra/iam.tf).
data "aws_iam_policy_document" "ci_plan_denies" {
  statement {
    sid    = "NeverReadParameters"
    effect = "Deny"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
      "ssm:GetParameterHistory",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ci_plan_denies" {
  name   = "${var.project_name}-ci-plan-denies"
  role   = aws_iam_role.ci_plan.id
  policy = data.aws_iam_policy_document.ci_plan_denies.json
}

# ── The deploy role: main only, broad, with explicit denies ───────────────────

data "aws_iam_policy_document" "ci_deploy_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_token_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Only jobs that run in the GitHub environment named here, which GitHub
    # lets protected branches (main) deploy to and nothing else. A pull request
    # or any other branch presents a different subject.
    condition {
      test     = "StringEquals"
      variable = "${local.github_token_issuer}:sub"
      values   = ["${var.github_subject}:environment:${var.github_deploy_environment}"]
    }
  }
}

resource "aws_iam_role" "ci_deploy" {
  name               = "${var.project_name}-ci-deploy"
  description        = "Assumed by GitHub Actions to deploy main: AdministratorAccess minus explicit denies (ADR 0012)."
  assume_role_policy = data.aws_iam_policy_document.ci_deploy_trust.json
}

# The main configuration manages S3, Lambda, ECR, Step Functions, Scheduler,
# SNS, CloudWatch and IAM roles, so the role that applies it needs wide rights,
# IAM included; AWS's ready-made policy for that is AdministratorAccess
# (ADR 0012). What it must never do is denied below, and a deny always wins.
resource "aws_iam_role_policy_attachment" "ci_deploy_admin" {
  role       = aws_iam_role.ci_deploy.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

data "aws_iam_policy_document" "ci_deploy_denies" {
  # Everything the plan role is denied (reading parameters, so the API key)...
  source_policy_documents = [data.aws_iam_policy_document.ci_plan_denies.json]

  # ...and what would end the Free Plan and its credits at once (ADR 0003),
  # with the other account-wide services a deploy never needs.
  statement {
    sid    = "NeverTouchTheAccountOrItsBilling"
    effect = "Deny"
    actions = [
      "organizations:*",
      "controltower:*",
      "account:*",
      "aws-marketplace:*",
      "savingsplans:*",
      "supportplans:*",
      "billing:*",
      "payments:*",
      "freetier:*",
      "ec2:Purchase*",
      "rds:PurchaseReserved*",
      "elasticache:PurchaseReserved*",
      "redshift:PurchaseReserved*",
      "dynamodb:PurchaseReserved*",
      "es:PurchaseReserved*",
      "memorydb:PurchaseReserved*",
    ]
    resources = ["*"]
  }

  # CI's own identity belongs to this bootstrap, applied from the laptop: CI
  # may not widen its own rights, or break the way it signs in.
  statement {
    sid     = "NeverChangeCiIdentity"
    effect  = "Deny"
    actions = ["iam:*"]
    resources = [
      aws_iam_openid_connect_provider.github.arn,
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-ci-*",
    ]
  }

  # Users, access keys and passwords would outlive any workflow run: a way to
  # keep access after the run's credentials expire. Nothing here needs them.
  statement {
    sid    = "NeverCreateLongLivedCredentials"
    effect = "Deny"
    actions = [
      "iam:CreateUser",
      "iam:CreateAccessKey",
      "iam:CreateLoginProfile",
      "iam:UpdateLoginProfile",
    ]
    resources = ["*"]
  }

  # The state bucket's settings, and the bootstrap's own state, belong to this
  # configuration. CI only reads and writes the main configuration's state
  # (infra/terraform.tfstate and its lock file).
  statement {
    sid    = "NeverChangeTheStateBucket"
    effect = "Deny"
    actions = [
      "s3:DeleteBucket*",
      "s3:PutBucket*",
      "s3:PutLifecycleConfiguration",
      "s3:PutEncryptionConfiguration",
    ]
    resources = [aws_s3_bucket.tfstate.arn]
  }

  statement {
    sid       = "NeverWriteTheBootstrapState"
    effect    = "Deny"
    actions   = ["s3:PutObject", "s3:DeleteObject", "s3:DeleteObjectVersion"]
    resources = ["${aws_s3_bucket.tfstate.arn}/bootstrap/*"]
  }

  # The raw history is the project's reason to exist, and the API can't return
  # it again (ADR 0005). Terraform never writes or deletes an object in raw/.
  statement {
    sid       = "NeverRewriteRawHistory"
    effect    = "Deny"
    actions   = ["s3:PutObject", "s3:DeleteObject", "s3:DeleteObjectVersion"]
    resources = ["arn:aws:s3:::${var.project_name}-${data.aws_caller_identity.current.account_id}/raw/*"]
  }
}

resource "aws_iam_role_policy" "ci_deploy_denies" {
  name   = "${var.project_name}-ci-deploy-denies"
  role   = aws_iam_role.ci_deploy.id
  policy = data.aws_iam_policy_document.ci_deploy_denies.json
}
