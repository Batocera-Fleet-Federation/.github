output "ecr_repository_url" {
  description = "ECR repository URL for Overmind images."
  value       = aws_ecr_repository.overmind.repository_url
}

output "overmind_url" {
  description = "Public Overmind URL."
  value       = "https://${var.overmind_domain_name}"
}

output "overmind_public_ip" {
  description = "Elastic IP assigned to Overmind."
  value       = aws_eip.overmind.public_ip
}

output "route53_record_created" {
  description = "Whether Terraform created the Overmind subdomain A record."
  value       = var.create_route53_record
}

output "manual_dns_record" {
  description = "Create this DNS record outside Terraform when create_route53_record=false."
  value = {
    name  = var.overmind_domain_name
    type  = "A"
    value = aws_eip.overmind.public_ip
  }
}

output "rds_endpoint" {
  description = "RDS endpoint. Password is stored in Secrets Manager and not output."
  value       = aws_db_instance.overmind.address
}

output "runtime_secret_arn" {
  description = "Secrets Manager ARN containing runtime database credentials and SECRET_KEY."
  value       = aws_secretsmanager_secret.overmind_runtime.arn
}

output "github_actions_role_arn" {
  description = "GitHub Actions OIDC role ARN."
  value       = aws_iam_role.github_deploy.arn
}

output "ec2_instance_id" {
  description = "Overmind EC2 instance ID, used by the deploy workflow through SSM."
  value       = aws_instance.overmind.id
}
