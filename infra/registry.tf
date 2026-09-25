# The container registry for the transform function's image (Phase 2).
#
# Lambda runs container images only from ECR, in its own region. Terraform
# never builds or pushes an image: scripts/build_transform_image.ps1 -Push does,
# and compute.tf deploys what it pushed, by digest.
#
# First deployment only (the function needs an image, which needs a repository):
#   terraform apply "-target=aws_ecr_repository.transform"
#   ./scripts/build_transform_image.ps1 -Push
#   terraform apply
# The quotes matter in PowerShell, which otherwise splits the argument at the
# dot and hands Terraform two arguments.

resource "aws_ecr_repository" "transform" {
  name = local.transform_function_name

  # Once pushed, a tag always means the same image. Tags record the recipe
  # (<app_version>-<commit>); this makes that record trustworthy.
  image_tag_mutability = "IMMUTABLE"

  # Basic scanning is free: every push is checked against known vulnerabilities
  # in the image's OS and Python packages. Results:
  #   aws ecr describe-image-scan-findings --repository-name <name> --image-id imageTag=<tag>
  image_scanning_configuration {
    scan_on_push = true
  }

  # Unlike the raw history (ADR 0005), images can be rebuilt from git at any
  # time, so destroy may delete a repository that still holds some.
  force_delete = true
}

resource "aws_ecr_lifecycle_policy" "transform" {
  repository = aws_ecr_repository.transform.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only the ${var.ecr_images_to_keep} most recently pushed images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = var.ecr_images_to_keep
      }
      action = { type = "expire" }
    }]
  })
}

# A resource policy: attached to the repository, it says who may use it, where
# the roles in iam.tf say what an identity may do. Within one account either
# side may let Lambda pull the image. It is granted here because if neither side
# does, Lambda adds a statement to this policy itself when the function is
# created - a change Terraform would not know about.
#
# The function's ARN is written out (compute.tf) rather than referenced: the
# function depends on this policy, so a reference back would be a cycle. The
# second value also covers an ARN with a version or alias suffix.
data "aws_iam_policy_document" "transform_image_pull" {
  statement {
    sid     = "LambdaPullForTransformFunctionOnly"
    effect  = "Allow"
    actions = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [local.transform_function_arn, "${local.transform_function_arn}:*"]
    }
  }
}

resource "aws_ecr_repository_policy" "transform" {
  repository = aws_ecr_repository.transform.name
  policy     = data.aws_iam_policy_document.transform_image_pull.json
}
