# Every value that might reasonably change lives here, so the resource files
# read as a description of the architecture rather than a list of constants.

variable "aws_region" {
  description = "Region for all resources. af-south-1 is Cape Town."
  type        = string
  default     = "af-south-1"
}

variable "aws_profile" {
  description = "Local AWS CLI profile used to authenticate (see ADR 0004)."
  type        = string
  default     = "eskom-admin"
}

variable "project_name" {
  description = "Name prefix and project tag for every resource."
  type        = string
  default     = "eskom-grid"
}

variable "app_version" {
  description = <<-EOT
    Git tag of eskom-grid-observability that the Lambda package is built from.
    The single source of truth: the build script reads this default, and a
    precondition in compute.tf fails the plan if build/ holds a different
    version. Never point this at a branch.
  EOT
  type        = string
  default     = "v0.3.1"
}

variable "api_key_parameter_name" {
  description = <<-EOT
    SSM Parameter Store name holding the EskomSePush API key. The parameter is
    created out of band with the AWS CLI so that its value never enters
    Terraform code or state — see the README.
  EOT
  type        = string
  default     = "/eskom-grid/api-key"
}

variable "schedule_expression" {
  description = <<-EOT
    EventBridge Scheduler cron. Six fields — minute, hour, day-of-month, month,
    day-of-week, year — and one of the day fields must be '?'. This is NOT the
    five-field Unix cron used by the local Dagster schedule.
    Hourly with two areas = 48 API calls/day against a 50/day free-tier quota.
  EOT
  type        = string
  default     = "cron(0 * * * ? *)"
}

variable "schedule_timezone" {
  description = "IANA timezone the schedule is interpreted in."
  type        = string
  default     = "Africa/Johannesburg"
}

variable "lambda_runtime" {
  description = "Lambda Python runtime. Matches the local development venv."
  type        = string
  default     = "python3.13"
}

variable "lambda_architecture" {
  description = "arm64 (Graviton) costs less per GB-second than x86_64."
  type        = string
  default     = "arm64"
}

variable "lambda_timeout_seconds" {
  description = <<-EOT
    Generous relative to the work (two HTTP calls plus two small writes), but
    below it sits the application's own 30s per-request HTTP timeout, so a
    hanging API fails inside the function rather than at the Lambda boundary.
  EOT
  type        = number
  default     = 60
}

variable "lambda_memory_mb" {
  description = <<-EOT
    Lambda allocates CPU in proportion to memory, so a small bump shortens the
    run. Billing is GB-seconds, so more memory for less time is roughly cost
    neutral — and this workload is far inside the always-free allowance anyway.
  EOT
  type        = number
  default     = 256
}

variable "log_retention_days" {
  description = "CloudWatch log retention. Without this, logs are kept forever."
  type        = number
  default     = 14
}

variable "noncurrent_version_expiration_days" {
  description = "How long superseded S3 object versions are kept before deletion."
  type        = number
  default     = 30
}
