output "namespace" {
  value = local.ns
}

output "hostname" {
  value       = local.hostname
  description = "Public HTTPS endpoint for the app"
}

output "image" {
  value = "${var.image}:${var.image_tag}"
}

output "s3_bucket" {
  value = local.s3_bucket_id
}

output "iam_user" {
  value = try(aws_iam_user.app[0].name, null)
}

output "secrets_manager_aws_secret_name" {
  value       = local.aws_sm_aws_arn_name
  description = "AWS Secrets Manager secret holding the app's S3 IAM keys (managed by Terraform)"
}

output "secrets_manager_integrations_secret_name" {
  value       = local.aws_sm_integrations_arn_name
  description = "AWS Secrets Manager secret to populate with 3rd-party API keys (NOT managed by Terraform)"
}
