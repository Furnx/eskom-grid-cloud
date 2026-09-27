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

variable "github_subject" {
  description = <<-EOT
    How GitHub names this repository in its OIDC tokens: the start of the "sub"
    claim that CI's trust policies match. Repositories created since July 2026
    get immutable subjects, where the owner's and the repository's ID numbers
    follow their names (Furnx@89989017/eskom-grid-cloud@1379288500), so a
    repository deleted and re-created under the same name gets new IDs and
    can't use these roles. Read it from GitHub, never from memory:
      gh api repos/Furnx/eskom-grid-cloud/actions/oidc/customization/sub
  EOT
  type        = string
  default     = "repo:Furnx@89989017/eskom-grid-cloud@1379288500"
}

variable "github_deploy_environment" {
  description = <<-EOT
    The GitHub environment the deploy workflow runs in. The deploy role trusts
    only jobs in it, and GitHub lets only protected branches (main) deploy to
    it. Created once in the repository's settings (see the README).
  EOT
  type        = string
  default     = "production"
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
