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

variable "domain_name" {
  description = "Root domain hosted for Batocera Swarm."
  type        = string
  default     = "batocera-swarm.com"
}

variable "overmind_subdomain" {
  description = "Subdomain for Overmind. Empty string hosts Overmind at the apex domain."
  type        = string
  default     = ""
}

variable "overmind_domain_name" {
  description = "Optional full hostname override for Overmind. Empty uses overmind_subdomain.domain_name or the apex."
  type        = string
  default     = ""
}

variable "hosted_zone_name" {
  description = "Existing Route 53 hosted zone name when create_hosted_zone=false and hosted_zone_id is empty."
  type        = string
  default     = "batocera-swarm.com"
}

variable "create_hosted_zone" {
  description = "Create a public Route 53 hosted zone for domain_name."
  type        = bool
  default     = false
}

variable "hosted_zone_id" {
  description = "Existing Route 53 hosted zone ID. Leave empty to look up hosted_zone_name or create a new zone."
  type        = string
  default     = ""
}

variable "create_route53_record" {
  description = "Create Route 53 A records for the apex, www, and Overmind hostname."
  type        = bool
  default     = false
}

variable "certificate_sans" {
  description = "Additional ACM certificate subject alternative names."
  type        = list(string)
  default     = []
}

variable "create_acm_validation_records" {
  description = "Create Route 53 DNS validation records for the ACM certificate."
  type        = bool
  default     = true
}

variable "route53_mail_records" {
  description = "Additional Route 53 mail-related DNS records, keyed by a stable record id. Use an empty name for the zone apex."
  type = map(object({
    name    = string
    type    = string
    ttl     = optional(number, 300)
    records = list(string)
  }))
  default = {}
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
  default     = ["10.42.10.0/24"]
}

variable "availability_zones" {
  description = "Optional explicit availability zones. Leave empty to discover available AZs."
  type        = list(string)
  default     = []
}

variable "ami_id" {
  description = "Optional AMI ID or EC2-supported SSM dynamic reference. Leave empty to discover latest Amazon Linux 2023."
  type        = string
  default     = ""
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

variable "use_fake_data" {
  description = "Whether to use fake data in Overmind for testing and development purposes. This may include mock game data, simulated user activity, or other non-production data to facilitate testing without affecting real data."
  type        = bool
  default     = false
}

variable "email_provider" {
  description = "Outbound email provider used by Overmind."
  type        = string
  default     = "smtp"
}

variable "email_from_address" {
  description = "Sender email address for Overmind mail."
  type        = string
  default     = ""
}

variable "smtp_host" {
  description = "SMTP server hostname."
  type        = string
  default     = "smtp.purelymail.com"
}

variable "smtp_port" {
  description = "SMTP server port."
  type        = number
  default     = 587
}

variable "smtp_username" {
  description = "SMTP username. Often the full Purelymail mailbox address."
  type        = string
  default     = ""
  sensitive   = true
}

variable "smtp_password" {
  description = "SMTP password."
  type        = string
  default     = ""
  sensitive   = true
}

variable "smtp_starttls" {
  description = "Use STARTTLS for SMTP."
  type        = bool
  default     = true
}

variable "runtime_secret_refresh_seconds" {
  description = "How often Overmind polls the runtime secret for updated ENV values."
  type        = number
  default     = 60
}

variable "runtime_secret_extra_env" {
  description = "Additional arbitrary runtime environment key/value pairs to merge into the existing Overmind runtime secret."
  type        = map(string)
  default     = {}
  sensitive   = true
}
