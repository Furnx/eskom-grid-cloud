# The bucket that holds Terraform's state: the main configuration's
# (infra/terraform.tfstate) and this one's (bootstrap/terraform.tfstate).
#
# State is Terraform's memory of what it manages, and it holds the alert
# address in plain text, so the bucket is private, encrypted and reachable only
# over TLS. Versioning is its undo button: every apply writes a new version, and
# a damaged state can be rolled back to the one before.

resource "aws_s3_bucket" "tfstate" {
  bucket = "${var.project_name}-tfstate-${data.aws_caller_identity.current.account_id}"

  # Without this bucket, Terraform forgets everything it manages. Terraform
  # refuses to plan its deletion; removing this block has to be deliberate.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# S3 encrypts every new object by default (SSE-S3). Declared anyway, so the
# setting is visible here and a change to it would show in a plan.
resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    id     = "expire-noncurrent-state"
    status = "Enabled"

    # The whole bucket.
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.state_noncurrent_version_expiration_days
    }
  }

  # Lifecycle rules are rejected while versioning is still being enabled.
  depends_on = [aws_s3_bucket_versioning.tfstate]
}

# Refuse any request not made over TLS. Terraform and the AWS CLI always use
# TLS; this makes it a rule rather than a habit.
data "aws_iam_policy_document" "tfstate" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.tfstate.arn, "${aws_s3_bucket.tfstate.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  policy = data.aws_iam_policy_document.tfstate.json

  # S3 rejects a bucket policy while the public access block is still being set.
  depends_on = [aws_s3_bucket_public_access_block.tfstate]
}
