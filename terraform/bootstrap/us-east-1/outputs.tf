output "state_bucket_name" {
  description = "S3 bucket for Terraform state."
  value       = aws_s3_bucket.terraform_state.bucket
}

output "lock_table_name" {
  description = "DynamoDB table for Terraform state locks."
  value       = aws_dynamodb_table.terraform_locks.name
}
