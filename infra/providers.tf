# Provider configuration and account lookup.
#
# The exact provider versions used are recorded in .terraform.lock.hcl, which is
# committed — that file, not these constraints, is what makes builds reproducible.

terraform {
  # use_lockfile (below) needs 1.11 or later.
  required_version = ">= 1.11"

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

  # State lives in S3 (ADR 0011), in the bucket infra/bootstrap creates, so the
  # laptop and a CI runner share one memory of what exists. While a run is
  # changing things, use_lockfile keeps a lock file beside the state
  # (infra/terraform.tfstate.tflock), so two runs can't write at once.
  #
  # A backend can't use variables, hence the literal names. No profile here:
  # CI brings its credentials in environment variables, and the laptop names
  # its profile once, when it initialises:
  #   terraform init -backend-config="profile=eskom-admin"
  backend "s3" {
    bucket       = "eskom-grid-tfstate-433490648023"
    key          = "infra/terraform.tfstate"
    region       = "af-south-1"
    use_lockfile = true
    encrypt      = true
  }
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
