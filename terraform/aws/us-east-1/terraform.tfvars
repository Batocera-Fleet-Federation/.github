aws_region           = "us-east-1"
project_name         = "bff-overmind"
environment          = "prod"
overmind_version     = "v0.0.16-alpha"
domain_name          = "batocera-swarm.com"
overmind_subdomain   = "www"
overmind_domain_name = ""
hosted_zone_name     = "batocera-swarm.com"

# Set create_hosted_zone=true when this stack should create the public hosted zone.
# If the hosted zone already exists, set create_hosted_zone=false and provide hosted_zone_id
# or hosted_zone_name.
create_hosted_zone    = true
hosted_zone_id        = ""
create_route53_record = true

certificate_sans = [
  "www.batocera-swarm.com"
]
create_acm_validation_records = true

route53_mail_records = {
  purelymail_apex_txt = {
    name = ""
    type = "TXT"
    records = [
      "purelymail_ownership_proof=16b98f59488ec1c14895b8509f291927d6a631945e296524cc0b8a564117dfe9593c0d927d302bdf73400604b7c1f52e033e43536c11c5041bc510181cd315f0",
      "v=spf1 include:_spf.purelymail.com ~all",
    ]
  }
  purelymail_mx = {
    name    = ""
    type    = "MX"
    records = ["10 mailserver.purelymail.com."]
  }
  purelymail_dkim_1 = {
    name    = "purelymail1._domainkey"
    type    = "CNAME"
    records = ["key1.dkimroot.purelymail.com."]
  }
  purelymail_dkim_2 = {
    name    = "purelymail2._domainkey"
    type    = "CNAME"
    records = ["key2.dkimroot.purelymail.com."]
  }
  purelymail_dkim_3 = {
    name    = "purelymail3._domainkey"
    type    = "CNAME"
    records = ["key3.dkimroot.purelymail.com."]
  }
  purelymail_dmarc = {
    name    = "_dmarc"
    type    = "CNAME"
    records = ["dmarcroot.purelymail.com."]
  }
}

email_provider     = "smtp"
email_from_address = "no-reply@batocera-swarm.com"
smtp_host          = "smtp.purelymail.com"
smtp_port          = 587
smtp_username      = "no-reply@batocera-swarm.com"
smtp_starttls      = true

# After Terraform initially creates bff-overmind/prod/runtime, manage SMTP_PASSWORD,
# GOOGLE_CLIENT_ID/SECRET, and GITHUB_CLIENT_ID/SECRET directly in that secret.
# Terraform is configured to preserve its existing payload on later applies.

ecr_repository_name       = "batocera-overmind"
instance_type             = "t3.micro"
db_instance_class         = "db.t3.micro"
availability_zones        = ["us-east-1a", "us-east-1b"]
public_subnet_cidrs       = ["10.42.10.0/24", "10.42.20.0/24"]
private_subnet_cidrs      = ["10.42.110.0/24", "10.42.120.0/24"]
ami_id                    = ""
lambda_create_nat_gateway = true

# Optional temporary RDS admin access. Set to your current public IP or CIDR
# such as "203.0.113.10" or "203.0.113.10/32"; leave empty to keep RDS private.
db_public_access_cidr = "72.176.228.250"

# Optional break-glass SSH. Prefer SSM Session Manager.
admin_ssh_cidr = ""
ssh_key_name   = ""

github_org    = "Batocera-Fleet-Federation"
github_repo   = "batocera.overmind"
github_branch = "main"

# Optional: creates private CA material in Secrets Manager and Terraform state.
enable_internal_ca_secret = true
