# TL;DR Terraform with Values

For immediate deployment with sensible defaults:

```bash
cd .github/terraform/aws/us-east-1
cp terraform.tfvars.example terraform.tfvars

# Minimal required edits (replace with your values):
sed -i '' \
  -e 's/domain_name = "batocera-swarm.com"/domain_name = "yourdomain.com"/' \
  -e 's/github_org = "Batocera-Fleet-Federation"/github_org = "YOUR-ORG"/' \
  -e 's/github_repo = "batocera.overmind"/github_repo = "YOUR-REPO"/' \
  terraform.tfvars

# Or edit manually and ensure these are set:
# domain_name          = "yourdomain.com"
# github_org           = "YOUR-GITHUB-ORG"
# github_repo          = "YOUR-GITHUB-REPO"
# create_hosted_zone   = true              (or false if zone exists)
# aws_region           = "us-east-1"

# Then apply:
terraform init && terraform fmt && terraform validate && terraform apply
```

Outputs needed for GitHub Actions setup:
```bash
terraform output -json | jq '.github_actions_role_arn.value, .ecr_repository_url.value, .ec2_instance_id.value'
```

# Batocera Overmind on AWS, us-east-1

**Status: ✅ Ready to deploy** against existing AWS accounts.

This Terraform stack deploys Overmind on low-cost AWS infrastructure:

- Amazon ECR repository for the Overmind image.
- One Amazon Linux 2023 EC2 instance running Docker.
- Caddy in Docker for public HTTPS and automatic Let's Encrypt certificates.
- Private RDS PostgreSQL, reachable only from the Overmind instance security group.
- AWS Secrets Manager for database credentials and `SECRET_KEY`.
- SSM Session Manager/Run Command for deployment, so SSH can stay disabled.
- GitHub Actions OIDC role for image push and SSM deployment.
- Optional Route 53 public hosted zone for `batocera-swarm.com`.
- ACM public certificate for `batocera-swarm.com`, `www.batocera-swarm.com`, and configured SANs, with optional DNS validation records.

The default public hostname is `batocera-swarm.com`. Set `overmind_subdomain = "overmind"` if you want Overmind at `overmind.batocera-swarm.com` while still creating root and `www` records.

## Quick Start (5 Steps)

**Prerequisites:**
- AWS account with admin IAM permissions
- Terraform ≥ 1.6 installed locally
- Push access to `Batocera-Fleet-Federation/batocera.overmind` on GitHub
- A domain name you own (or use `batocera-swarm.com` for testing)

**Deployment:**

```bash
# 1. Prepare configuration
cd .github/terraform/aws/us-east-1
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: domain_name, github_org, github_repo, create_hosted_zone

# 2. Initialize and validate
terraform init && terraform fmt && terraform validate

# 3. Plan and apply
terraform plan
terraform apply

# 4. Capture outputs for GitHub Actions
terraform output github_actions_role_arn
terraform output ecr_repository_url
terraform output ec2_instance_id

# 5. Deploy (auto on git push, or manual via SSM)
# After apply, push to main branch → GitHub Actions deploys
# OR manually trigger: aws ssm send-command \
#   --instance-ids "$(terraform output -raw ec2_instance_id)" \
#   --document-name AWS-RunShellScript \
#   --parameters commands='["/opt/overmind/deploy.sh"]'
```

**Estimated time:** ~15–20 minutes (init: 2–5s, apply: 8–12min, DNS propagation: 5–10min).

## Architecture Choice

The initial compute target is EC2 + Docker instead of ECS/Fargate + ALB. That keeps the resource list small and avoids always-on ALB and NAT Gateway costs. HTTPS for the EC2-hosted app is handled by Caddy with Let's Encrypt because ACM public certificates cannot be exported and attached directly to a process on EC2. The stack still provisions an ACM certificate for future ALB/CloudFront use and for domain readiness.

## Public TLS vs Internal Drone CA

Public browser TLS is provided by Caddy/Let's Encrypt for the configured Overmind hostname. ACM certificate DNS validation records are also managed when `create_acm_validation_records = true`.

The optional `enable_internal_ca_secret` variable creates a separate private CA secret for future Drone trust workflows. That private key is stored in Secrets Manager and Terraform state, so leave it disabled unless the application explicitly needs Terraform-created internal CA material.

## Detailed Configuration

Edit `terraform.tfvars` with your environment:

```hcl
# Domain and DNS
domain_name          = "batocera-swarm.com"      # Your registered domain
overmind_subdomain   = ""                        # "" for apex, "overmind" for subdomain
create_hosted_zone   = true                      # true: create new zone, false: use existing
hosted_zone_id       = ""                        # If using existing zone, set ID
create_route53_record = true                     # Create A records for root/www/overmind

# GitHub OIDC for CI/CD
github_org    = "Batocera-Fleet-Federation"     # Org name
github_repo   = "batocera.overmind"             # Repo containing deploy workflow
github_branch = "main"                          # Branch allowed to deploy

# AWS & compute
aws_region    = "us-east-1"
instance_type = "t3.micro"                      # t3.micro is free-tier eligible
ami_id        = "resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"

# Database
db_instance_class = "db.t3.micro"               # Upgrade to db.t3.small for production
db_allocated_storage = 20                       # GiB
db_deletion_protection = false                  # Set true for production

# Optional: break-glass SSH access
admin_ssh_cidr = ""                             # Leave empty to disable SSH
ssh_key_name   = ""                             # EC2 key pair name if needed

# Optional: internal CA for Drone trust (rarely used)
enable_internal_ca_secret = false
```

**DNS scenarios:**

1. **New domain + new hosted zone:**
   ```hcl
   create_hosted_zone    = true
   create_route53_record = true
   ```
   After apply, point domain registrar to nameservers from `terraform output hosted_zone_nameservers`.

2. **Existing hosted zone in AWS:**
   ```hcl
   create_hosted_zone    = false
   hosted_zone_id        = "Z1234567890ABC"
   create_route53_record = true
   ```

3. **DNS managed elsewhere (no Route 53 records):**
   ```hcl
   create_hosted_zone    = false
   create_route53_record = false
   ```
   Create A records manually using `terraform output manual_dns_record` values.

## GitHub Actions Setup

After `terraform apply` succeeds, configure GitHub Actions repository variables in `Batocera-Fleet-Federation/batocera.overmind`:

Settings → Secrets and variables → Actions → Repository variables

| Variable | Value |
|----------|-------|
| `AWS_REGION` | `us-east-1` |
| `AWS_ROLE_TO_ASSUME` | `terraform output github_actions_role_arn` |
| `ECR_REPOSITORY` | `batocera-overmind` |
| `OVERMIND_ENVIRONMENT` | `prod` |
| `OVERMIND_PROJECT_NAME` | `bff-overmind` |

**No AWS credentials needed.** The workflow uses GitHub OIDC to assume the deploy role.

## Deployment Workflows

**Automatic deployment on git push:**
- Push to `main` → GitHub Actions builds, pushes to ECR, and deploys via SSM.

**Manual deployment via SSM:**
```bash
aws ssm send-command \
  --region us-east-1 \
  --instance-ids "$(terraform output -raw ec2_instance_id)" \
  --document-name AWS-RunShellScript \
  --parameters commands='["/opt/overmind/deploy.sh IMAGE_TAG"]'
```
Replace `IMAGE_TAG` with ECR image tag (e.g., `latest` or git SHA).

**Manual dispatch from GitHub:**
The `.github/workflows/deploy-overmind-aws.yml` workflow supports `workflow_dispatch` for on-demand deployments from the GitHub UI.

## Application Persistence

Overmind reads PostgreSQL settings from Secrets Manager and receives these env vars:

- `OVERMIND_POSTGRES_HOST`
- `OVERMIND_POSTGRES_PORT`
- `OVERMIND_POSTGRES_DB`
- `OVERMIND_POSTGRES_USER`
- `OVERMIND_POSTGRES_PASSWORD`
- `SECRET_KEY`
- `OVERMIND_ENVIRONMENT=prod`

In production mode, startup fails clearly if PostgreSQL configuration is absent.

## Smoke Test

After Terraform and DNS:

1. Run the deploy workflow.
2. Visit `https://batocera-swarm.com/`.
3. Create an Overlord user.
4. Generate a Drone token.
5. Restart the app container:
   ```bash
   aws ssm send-command \
     --instance-ids "$(terraform output -raw ec2_instance_id)" \
     --document-name AWS-RunShellScript \
     --parameters commands='["sudo systemctl restart overmind.service"]'
   ```
6. Log in again and confirm the user and Drone token data persisted.
7. Confirm `https://batocera-swarm.com` is unchanged.

## Known Limitations & Next Steps

**Email verification (Purelymail SMTP):**
Overmind sends production email through SMTP when `EMAIL_PROVIDER=smtp`. DNS and SMTP settings are driven from `terraform.tfvars`:
1. Keep the Purelymail TXT, MX, DKIM, SPF, and DMARC records in `route53_mail_records`.
2. Set `email_from_address`, `smtp_username`, and `smtp_password` for the Purelymail mailbox.
3. Terraform stores the SMTP runtime settings in Secrets Manager and the EC2 deployment loads them into the container environment.
4. Optional sender branding is controlled by `EMAIL_FROM_DISPLAY_NAME`; when set, outbound mail uses `Display Name <email@domain.com>`.

**Runtime override secret (`overmind`):**
Terraform creates an AWS Secrets Manager secret named `overmind` but does not create a secret version or commit secret values. Operators can manage runtime overrides manually:
```bash
aws secretsmanager put-secret-value \
  --secret-id overmind \
  --secret-string '{
    "SMTP_USERNAME": "admin@theoutlawoasis.com",
    "SMTP_PASSWORD": "secret-value",
    "EMAIL_FROM": "noreply@theoutlawoasis.com",
    "EMAIL_FROM_DISPLAY_NAME": "Batocera Overmind"
  }'
```

The EC2 instance role can read only the generated deployment secret, the optional internal CA secret, and the `overmind` override secret. Every key in the `overmind` JSON object is applied as an environment variable override inside the app. Secret values override container env values and are never logged. Overmind polls the secret every `runtime_secret_refresh_seconds` seconds, applies changed values without restarting for runtime-read settings such as SMTP/email configuration, and keeps the last known good values if refresh fails. Settings captured by long-lived library state may still require a restart; `SECRET_KEY` and `TOKEN_HASH_SECRET` are explicitly refreshed in the app.

**RDS burstable instance:**
`db.t3.micro` is appropriate for development. For production traffic, upgrade to `db.t3.small` or `db.t3.medium` and set `db_deletion_protection = true`.

**Caddy Let's Encrypt:**
Requires ports 80 and 443 open to the internet during certificate issuance and renewal. If your firewall blocks outbound ACME, configure a custom ACME provider.

**GitHub OIDC provider:**
If your AWS account already has a GitHub OIDC provider, Terraform will fail to create a duplicate. Either:
- Import the existing provider: `terraform import aws_iam_openid_connect_provider.github <provider_arn>`
- Comment out the `aws_iam_openid_connect_provider` resource and update `aws_iam_role` assumptions to reference the existing provider.

**Terraform state security:**
This stack stores sensitive data (RDS password, internal CA key if enabled) in Terraform state. Use remote state with encryption (e.g., S3 + DynamoDB lock) for production:
```bash
# terraform backend config (create backend.tf or use -backend-config flags)
terraform init -backend-config="bucket=my-tf-state" \
               -backend-config="key=bff-overmind/prod/terraform.tfstate" \
               -backend-config="dynamodb_table=terraform-lock" \
               -backend-config="region=us-east-1" \
               -backend-config="encrypt=true"
```

## Cost Notes

Cost-impacting resources:

- EC2 `t3.micro` instance and public IPv4/Elastic IP.
- RDS PostgreSQL `db.t3.micro` and 20 GiB storage.
- Route 53 hosted zone if one exists or is created elsewhere.
- ECR image storage after free allowances.
- Data transfer and CloudWatch/SSM operational logs.

This stack intentionally avoids NAT Gateway, ALB, ECS/Fargate, and Multi-AZ RDS by default.

## Architecture Choices

The initial compute target is EC2 + Docker instead of ECS/Fargate + ALB. That keeps the resource list small and avoids always-on ALB and NAT Gateway costs. HTTPS for the EC2-hosted app is handled by Caddy with Let's Encrypt because ACM public certificates cannot be exported and attached directly to a process on EC2. The stack still provisions an ACM certificate for future ALB/CloudFront use and for domain readiness.

Public browser TLS is provided by Caddy/Let's Encrypt for the configured Overmind hostname. ACM certificate DNS validation records are also managed when `create_acm_validation_records = true`.

The optional `enable_internal_ca_secret` variable creates a separate private CA secret for future Drone trust workflows. That private key is stored in Secrets Manager and Terraform state, so leave it disabled unless the application explicitly needs Terraform-created internal CA material.
