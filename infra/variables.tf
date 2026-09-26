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
  default     = "v0.3.2"
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
  description = "How long superseded versions of raw/ objects are kept before deletion."
  type        = number
  default     = 30
}

# ── Transform (Phase 2) ──────────────────────────────────────────────────────
# The lambda_* variables above belong to the extract function; the transform's
# workload is different enough to need its own.

variable "transform_memory_mb" {
  description = <<-EOT
    Memory for the transform Lambda; CPU scales with it. Measured 2026-09-26:
    an hourly run peaks at about 400 MB and bills 11-12 s. Kept at 1024: less
    memory would mostly mean less CPU and a longer run at about the same cost,
    with little headroom. Re-check "Max Memory Used" in the REPORT lines as the
    warehouse grows.
  EOT
  type        = number
  default     = 1024
}

variable "transform_timeout_seconds" {
  description = <<-EOT
    Under arm64 emulation on a laptop, a warm run took 43 s and a full first
    run 101 s; Graviton is faster. Generous, so that a slow S3 day still
    finishes and a stuck run fails clearly.
  EOT
  type        = number
  default     = 300
}

variable "warehouse_noncurrent_version_expiration_days" {
  description = <<-EOT
    How long superseded versions of the warehouse file are kept. It is replaced
    every hour (a few MB each time) and can be rebuilt from raw/, so a short
    window is enough.
  EOT
  type        = number
  default     = 3
}

variable "ecr_images_to_keep" {
  description = <<-EOT
    Transform images kept in ECR (about 265 MB each). The rule counts pushes,
    not deployments, and a function whose image is deleted fails: always
    deploy after pushing, and never push more than this many without deploying.
  EOT
  type        = number
  default     = 3
}

# ── Alerting (Phase 3) ───────────────────────────────────────────────────────

variable "alert_email" {
  description = <<-EOT
    Address that receives failure alerts (ADR 0010). No default and never
    committed: set it in infra/terraform.tfvars, which is git-ignored. After
    the first apply AWS emails a confirmation link, and nothing is delivered
    until it is clicked.
  EOT
  type        = string

  # Plans then print it as "(sensitive value)". From Phase 4 they run in CI,
  # whose logs are visible to anyone who can see the repository.
  sensitive = true

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email must be an email address."
  }
}
