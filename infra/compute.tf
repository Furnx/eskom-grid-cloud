# The extract function.
#
# A zip deployment, not a container image: the package plus requests and pyyaml
# is a few megabytes, and boto3 ships inside the Lambda runtime. Phase 2's
# transform function will need an image, because dbt and DuckDB are far too
# large for a zip — the contrast is the point.
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
