# The same names and defaults as infra/variables.tf, so the two configurations
# describe the same account and region.

variable "aws_region" {
  description = "Region for all resources. af-south-1 is Cape Town."
  type        = string
  default     = "af-south-1"
}

variable "aws_profile" {
  description = "Local AWS CLI profile used to authenticate (see ADR 0004). The bootstrap only ever runs from the laptop."
  type        = string
  default     = "eskom-admin"
}

variable "project_name" {
  description = "Name prefix and project tag for every resource."
  type        = string
  default     = "eskom-grid"
}

variable "state_noncurrent_version_expiration_days" {
  description = <<-EOT
    How long superseded versions of a state file are kept. Every apply writes a
    new version (about 100 KB), and an old one is how a damaged state is rolled
    back, so they are kept for a generous window.
  EOT
  type        = number
  default     = 90
}
