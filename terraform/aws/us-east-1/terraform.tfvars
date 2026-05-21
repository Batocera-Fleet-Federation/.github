aws_region           = "us-east-1"
project_name         = "bff-overmind"
environment          = "prod"
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
  "www.batocera-swarm.com",
  "overmind.batocera-swarm.com",
]
create_acm_validation_records = true

ecr_repository_name = "batocera-overmind"
instance_type       = "t3.micro"
db_instance_class   = "db.t3.micro"
availability_zones  = ["us-east-1a", "us-east-1b"]
ami_id              = "resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"

# Optional break-glass SSH. Prefer SSM Session Manager.
admin_ssh_cidr = ""
ssh_key_name   = ""

github_org    = "Batocera-Fleet-Federation"
github_repo   = "batocera.overmind"
github_branch = "main"

# Optional: creates private CA material in Secrets Manager and Terraform state.
enable_internal_ca_secret = false
