output "state_bucket" {
  description = "Bucket holding Terraform's state. Named literally in both backend blocks, which can't use variables."
  value       = aws_s3_bucket.tfstate.bucket
}
