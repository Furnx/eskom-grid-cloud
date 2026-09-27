# The bootstrap: what must exist before the main configuration (infra/) can run,
# and what CI must never manage itself (ADR 0011).
#
#   state.tf        the bucket that holds Terraform's state, both this
#                   configuration's and the main one's
#   (Phase 4 adds)  the GitHub OIDC connection and CI's two roles
#
# Applied from the laptop by the account admin, rarely. Never by CI: a
# configuration that managed the role it runs as could widen its own
# permissions, or lock itself out with one bad apply.

terraform {
  # use_lockfile (below, and in infra/providers.tf) needs 1.11 or later.
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40, < 7.0"
    }
  }

  # This configuration's own state lives in the bucket it creates (state.tf).
  # A backend can't use variables, so the names are written out.
  #
  # First time in an account, that bucket doesn't exist yet. Start on a local
  # state, then move it in (override files are git-ignored, so this one never
  # gets committed):
  #   Set-Content backend_override.tf 'terraform {', '  backend "local" {}', '}'
  #   terraform init; terraform apply
  #   Remove-Item backend_override.tf
  #   terraform init -migrate-state
  backend "s3" {
    bucket       = "eskom-grid-tfstate-433490648023"
    key          = "bootstrap/terraform.tfstate"
    region       = "af-south-1"
    profile      = "eskom-admin"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = {
      project    = var.project_name
      managed_by = "terraform"
      repo       = "eskom-grid-cloud"
      stack      = "bootstrap"
    }
  }
}

# The account ID makes the bucket name globally unique, as in infra/storage.tf.
data "aws_caller_identity" "current" {}
