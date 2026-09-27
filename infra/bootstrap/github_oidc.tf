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

    # Only runs for a pull request in this repository. (GitHub gives a pull
    # request from someone's fork read-only permissions, so it can't request a
    # token in the first place.)
    condition {
      test     = "StringEquals"
      variable = "${local.github_token_issuer}:sub"
      values   = ["repo:${var.github_repository}:pull_request"]
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
