# Provider configuration and account lookup.
#
# The exact provider versions used are recorded in .terraform.lock.hcl, which is
# committed — that file, not these constraints, is what makes builds reproducible.

terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40, < 7.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  # State is local and git-ignored until Phase 4, when it moves to an S3 backend.
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  # Applied to every taggable resource, so nothing can be created untagged and
  # later go unrecognised in the console or on a bill.
  default_tags {
    tags = {
      project    = var.project_name
      managed_by = "terraform"
      repo       = "eskom-grid-cloud"
    }
  }
}

# The account ID is used to build the SSM parameter ARN and to give the S3
# bucket a globally unique name.
data "aws_caller_identity" "current" {}
