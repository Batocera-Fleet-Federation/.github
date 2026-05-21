output "ecr_repository_url" {
  description = "ECR repository URL for Overmind images."
  value       = aws_ecr_repository.overmind.repository_url
}

output "overmind_url" {
  description = "Public Overmind URL."
  value       = "https://${local.overmind_fqdn}"
}

output "overmind_public_ip" {
  description = "Elastic IP assigned to Overmind."
  value       = aws_eip.overmind.public_ip
}

output "route53_record_created" {
  description = "Whether Terraform created public domain A records."
  value       = var.create_route53_record
}

output "hosted_zone_id" {
  description = "Route 53 hosted zone ID used for domain DNS."
  value       = local.route53_zone_id
}

output "hosted_zone_nameservers" {
  description = "Nameservers for the newly-created hosted zone. Empty when using an existing zone."
  value       = var.create_hosted_zone ? aws_route53_zone.domain[0].name_servers : []
}

output "acm_certificate_arn" {
  description = "ACM certificate ARN for batocera-swarm.com and configured SANs."
  value       = aws_acm_certificate.domain.arn
}

output "acm_validation_records" {
  description = "DNS records needed to validate ACM if validation records are not managed automatically."
  value = {
    for option in aws_acm_certificate.domain.domain_validation_options : option.domain_name => {
      name  = option.resource_record_name
      type  = option.resource_record_type
      value = option.resource_record_value
    }
  }
}

output "domain_records" {
  description = "Public DNS A records managed or expected for the domain."
  value = {
    apex     = local.root_domain
    www      = local.www_domain
    overmind = local.overmind_fqdn
    value    = aws_eip.overmind.public_ip
  }
}

output "manual_dns_record" {
  description = "Create these DNS records outside Terraform when create_route53_record=false."
  value = {
    type    = "A"
    records = distinct([local.root_domain, local.www_domain, local.overmind_fqdn])
    value   = aws_eip.overmind.public_ip
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
