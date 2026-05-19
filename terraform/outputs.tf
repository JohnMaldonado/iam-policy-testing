output "developer_user_arn" {
  description = "ARN of the developer-test IAM user"
  value       = aws_iam_user.developer.arn
}

output "developer_access_key_id" {
  description = "Access key ID for developer-test (use for test scripts)"
  value       = aws_iam_access_key.developer.id
  sensitive   = true
}

output "developer_secret_access_key" {
  description = "Secret access key for developer-test"
  value       = aws_iam_access_key.developer.secret
  sensitive   = true
}

output "developer_console_password" {
  description = "Initial console password (change on first login)"
  value       = aws_iam_user_login_profile.developer.password
  sensitive   = true
}

output "developer_policy_arn" {
  description = "ARN of the custom developer IAM policy"
  value       = aws_iam_policy.developer.arn
}

output "developer_boundary_policy_arn" {
  description = "ARN of the permission boundary policy"
  value       = aws_iam_policy.developer_boundary.arn
}

output "sandbox_role_arn" {
  description = "ARN of the sandbox role that developer-test can assume"
  value       = aws_iam_role.developer_sandbox.arn
}

output "lab_vpc_id" {
  description = "ID of the lab VPC — used as the EC2 launch restriction target"
  value       = aws_vpc.lab.id
}

output "dev_bucket_name" {
  description = "Name of the Dev-tagged S3 bucket (accessible to developer-test)"
  value       = aws_s3_bucket.dev_team.id
}

output "production_bucket_name" {
  description = "Name of the production-tagged S3 bucket (blocked for developer-test)"
  value       = aws_s3_bucket.production.id
}

output "access_analyzer_arn" {
  description = "ARN of the IAM Access Analyzer"
  value       = aws_accessanalyzer_analyzer.lab.arn
}

output "access_analyzer_id" {
  description = "ID of the IAM Access Analyzer (used in test scripts)"
  value       = aws_accessanalyzer_analyzer.lab.id
}
