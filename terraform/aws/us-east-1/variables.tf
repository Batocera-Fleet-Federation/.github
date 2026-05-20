variable "aws_region" {
  description = "AWS region for Overmind."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short name used for AWS resource names."
  type        = string
  default     = "bff-overmind"
}

variable "environment" {
  description = "Deployment environment label."
  type        = string
  default     = "prod"
}

variable "overmind_domain_name" {
  description = "Subdomain for Overmind. This module only manages this record, never the apex or www records."
  type        = string
  default     = "overmind.theoutlawoasis.com"
}

variable "hosted_zone_name" {
  description = "Existing Route 53 hosted zone name. Leave create_route53_record=false if DNS is managed elsewhere."
  type        = string
  default     = "theoutlawoasis.com"
}

variable "create_route53_record" {
  description = "Create only the Overmind subdomain A record in the existing hosted zone."
  type        = bool
  default     = false
}

variable "ecr_repository_name" {
  description = "ECR repository for the Overmind container."
  type        = string
  default     = "batocera-overmind"
}

variable "ecr_max_image_count" {
  description = "Maximum ECR images retained by lifecycle policy."
  type        = number
  default     = 20
}

variable "vpc_cidr" {
  description = "CIDR for the dedicated Overmind VPC."
  type        = string
  default     = "10.42.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "Two public subnet CIDRs. RDS is private by public accessibility=false and security groups."
  type        = list(string)
  default     = ["10.42.10.0/24", "10.42.20.0/24"]
}

variable "admin_ssh_cidr" {
  description = "Optional CIDR allowed to SSH to the instance. Empty disables SSH ingress."
  type        = string
  default     = ""
}

variable "instance_type" {
  description = "EC2 instance size. t3.micro is free-tier-friendly where eligible."
  type        = string
  default     = "t3.micro"
}

variable "ssh_key_name" {
  description = "Optional EC2 key pair name for break-glass SSH access."
  type        = string
  default     = ""
}

variable "overmind_container_port" {
  description = "Port exposed by the Overmind container."
  type        = number
  default     = 8000
}

variable "db_instance_class" {
  description = "RDS PostgreSQL instance class."
  type        = string
  default     = "db.t3.micro"
}

variable "db_allocated_storage" {
  description = "RDS allocated storage in GiB."
  type        = number
  default     = 20
}

variable "db_name" {
  description = "PostgreSQL database name."
  type        = string
  default     = "overmind"
}

variable "db_username" {
  description = "PostgreSQL master username."
  type        = string
  default     = "overmind"
}

variable "db_engine_version" {
  description = "PostgreSQL engine version."
  type        = string
  default     = "16.3"
}

variable "db_deletion_protection" {
  description = "Enable deletion protection for RDS."
  type        = bool
  default     = false
}

variable "db_skip_final_snapshot" {
  description = "Skip final snapshot on RDS destroy. Set false for production."
  type        = bool
  default     = true
}

variable "github_org" {
  description = "GitHub organization or owner allowed to assume the deploy role."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository allowed to assume the deploy role, usually the .github infra repository."
  type        = string
}

variable "github_branch" {
  description = "Branch allowed to assume the deploy role."
  type        = string
  default     = "main"
}

variable "github_oidc_thumbprints" {
  description = "TLS thumbprints for GitHub Actions OIDC. Import/use an existing provider if your account already has one."
  type        = list(string)
  default     = ["6938fd4d98bab03faadb97b34396831e3780aea1", "1b511abead59c6ce207077c0bf0e0043b1382612"]
}

variable "enable_internal_ca_secret" {
  description = "Create an internal Drone trust CA secret for Overmind. Private key is stored in Secrets Manager and Terraform state."
  type        = bool
  default     = false
}
