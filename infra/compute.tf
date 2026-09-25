# The two functions: extract (a zip) and, further down, transform (an image).
#
# Extract is a zip deployment, not a container image: the package plus requests
# and pyyaml is a few megabytes, and boto3 ships inside the Lambda runtime. The
# transform function needs an image, because dbt and DuckDB are far too large
# for a zip — the contrast is the point.
#
# The zip contents are produced by scripts/build_lambda.ps1 BEFORE terraform
# runs. archive_file is a data source, so it is read during plan; it cannot
# depend on something Terraform creates during apply.

data "archive_file" "extract" {
  type        = "zip"
  source_dir  = "${path.module}/../build/lambda"
  output_path = "${path.module}/../build/extract.zip"
}

# Declared explicitly rather than left to Lambda, which would create it on first
# invocation with retention set to "never expire" and leave it behind on destroy.
resource "aws_cloudwatch_log_group" "extract" {
  name              = "/aws/lambda/${var.project_name}-extract"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "extract" {
  function_name = "${var.project_name}-extract"
  description   = "Fetches EskomSePush schedules for every configured area and writes raw JSON to S3 (app ${var.app_version})."
  role          = aws_iam_role.extract.arn

  # "<module>.<function>" — handler.py at the zip root, function lambda_handler.
  handler       = "handler.lambda_handler"
  runtime       = var.lambda_runtime
  architectures = [var.lambda_architecture]
  timeout       = var.lambda_timeout_seconds
  memory_size   = var.lambda_memory_mb

  filename = data.archive_file.extract.output_path

  # Lambda only redeploys the code when this hash changes, so a rebuilt zip with
  # identical contents is not republished on every apply.
  source_code_hash = data.archive_file.extract.output_base64sha256

  environment {
    variables = {
      # Same switch the Dagster asset reads locally, pointed at S3 instead of a
      # directory. The application code cannot tell the difference.
      ESKOM_RAW_SINK = "s3://${aws_s3_bucket.raw.bucket}/raw"

      # The NAME of the parameter, never the value.
      ESKOM_API_KEY_PARAM = var.api_key_parameter_name
    }
  }

  # Without this, Lambda may create the log group itself on first invocation
  # and Terraform's group creation then conflicts with it.
  depends_on = [aws_cloudwatch_log_group.extract]

  lifecycle {
    # The description above claims var.app_version, but the code comes from
    # whatever the build script installed. Refuse to plan if the two disagree,
    # rather than deploy one version under the other's label.
    precondition {
      condition     = try(trimspace(file("${path.module}/../build/app_version.txt")), "") == var.app_version
      error_message = "build/ was not built from app_version ${var.app_version} (or the build did not finish). Run ./scripts/build_lambda.ps1 and plan again."
    }
  }
}

# ── The transform function (Phase 2) ─────────────────────────────────────────
#
# A container image this time. scripts/build_transform_image.ps1 -Push builds
# it, pushes it to ECR (registry.tf) and records the tag it pushed in
# build/transform_image_tag.txt. Terraform looks that tag up in ECR and deploys
# the image by its digest.

locals {
  transform_function_name = "${var.project_name}-transform"

  # Written out rather than read from the function resource, so that the
  # repository policy the function depends on can name it (registry.tf).
  transform_function_arn = "arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:${local.transform_function_name}"

  # A missing file becomes "", and the precondition below explains what to do.
  transform_image_tag = try(trimspace(file("${path.module}/../build/transform_image_tag.txt")), "")
}

# Resolves the tag to the image's digest, and fails the plan if the tag was
# never pushed. Tags cannot be moved (registry.tf), but the digest is what gets
# deployed: it names the exact bytes, and the function's record then shows them.
data "aws_ecr_image" "transform" {
  repository_name = aws_ecr_repository.transform.name
  image_tag       = local.transform_image_tag

  lifecycle {
    precondition {
      condition     = startswith(local.transform_image_tag, "${var.app_version}-")
      error_message = "build/transform_image_tag.txt is missing or was not pushed from app_version ${var.app_version}. Run ./scripts/build_transform_image.ps1 -Push and plan again."
    }
  }
}

resource "aws_cloudwatch_log_group" "transform" {
  name              = "/aws/lambda/${local.transform_function_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "transform" {
  function_name = local.transform_function_name
  description   = "Builds the dbt models from the raw JSON in S3 and replaces the DuckDB warehouse (image ${local.transform_image_tag})."
  role          = aws_iam_role.transform.arn

  # No handler or runtime settings: the image carries both (its base image and
  # its CMD).
  package_type = "Image"
  image_uri    = "${aws_ecr_repository.transform.repository_url}@${data.aws_ecr_image.transform.image_digest}"

  # Fixed rather than var.lambda_architecture: the image is only ever built for
  # linux/arm64, and a mismatch would only surface at the first invocation.
  architectures = ["arm64"]
  timeout       = var.transform_timeout_seconds
  memory_size   = var.transform_memory_mb

  environment {
    variables = {
      # Read by the dbt project's source definition, in the application.
      ESKOM_RAW_GLOB = "s3://${aws_s3_bucket.raw.bucket}/raw/**/*.json"

      # Downloaded, rebuilt and replaced with a conditional write (ADR 0007).
      ESKOM_WAREHOUSE_URI = "s3://${aws_s3_bucket.raw.bucket}/warehouse/eskom_data.duckdb"
    }
  }

  # The log group for the same reason as extract's. The repository policy
  # because Lambda checks that it may pull the image when the function is created.
  depends_on = [
    aws_cloudwatch_log_group.transform,
    aws_ecr_repository_policy.transform,
  ]
}
