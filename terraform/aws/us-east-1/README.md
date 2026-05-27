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
terraform output -json | jq '.github_actions_role_arn.value, .ecr_repository_url.value, .lambda_api_endpoint.value'
```

# Batocera Overmind on AWS, us-east-1

**Status: ✅ Ready to deploy** against existing AWS accounts.

This Terraform stack deploys Overmind on low-cost serverless AWS infrastructure:

- Amazon ECR repository for the Overmind image.
- API Gateway HTTP API with low/medium/high Lambda tiers.
- API Gateway custom domains for public HTTPS using ACM.
- Private RDS PostgreSQL, reachable from Lambda security groups.
- AWS Secrets Manager for database credentials and `SECRET_KEY`.
- EventBridge scheduled maintenance jobs.
- GitHub Actions OIDC role for image push and Lambda deployment.
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
terraform output lambda_api_endpoint

# 5. Deploy
# After apply, push to main branch → GitHub Actions pushes ECR images.
```

**Estimated time:** ~15–20 minutes (init: 2–5s, apply: 8–12min, DNS propagation: 5–10min).

## Architecture Choice

The compute target is API Gateway + Lambda using one shared Overmind image with
separate low/medium/high memory tiers. This avoids an always-on EC2 instance,
ALB, or NAT Gateway for the core API path.

## Public TLS vs Internal Drone CA

Public browser TLS is provided by API Gateway custom domains with ACM. ACM
certificate DNS validation records are also managed when
`create_acm_validation_records = true`.

The optional `enable_internal_ca_secret` variable creates a separate private CA secret for future Drone trust workflows. That private key is stored in Secrets Manager and Terraform state, so leave it disabled unless the application explicitly needs Terraform-created internal CA material.

## Serverless Overmind

This stack provisions the Lambda/API Gateway deployment when
`enable_lambda_overmind = true`.

- API Gateway sends default/simple routes to the low-memory Lambda.
- Admin/device/log/system routes go to the medium-memory Lambda.
- ROM metadata, master asset, and bulk sync routes go to the high-memory Lambda.
- EventBridge runs scheduled maintenance jobs without long-lived app threads.
- Lambda reaches PostgreSQL directly by default. Set `enable_rds_proxy = true`
  to use RDS Proxy when the AWS account plan supports it.

Build and push the Lambda image from the Overmind repo before applying:

```bash
TAG=lambda-latest scripts/docker-publish-lambda-ecr.sh
```

After apply, test the serverless endpoint:

```bash
terraform output lambda_api_endpoint
```

Route 53 records point at API Gateway custom domains when
`create_route53_record = true`.

## Remote Terraform State

Bootstrap the remote state bucket and lock table first:

```bash
cd .github/terraform/bootstrap/us-east-1
terraform init
terraform apply
```

Then migrate this stack:

```bash
cd ../../aws/us-east-1
terraform init -migrate-state
```

The backend uses:

- S3 bucket: `bff-overmind-prod-terraform-state`
- State key: `aws/us-east-1/overmind.tfstate`
- DynamoDB lock table: `bff-overmind-prod-terraform-locks`

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

# AWS & Lambda compute
aws_region    = "us-east-1"
lambda_low_memory_mb    = 1024
lambda_medium_memory_mb = 2048
lambda_high_memory_mb   = 3008

# Database
db_instance_class = "db.t3.micro"               # Upgrade to db.t3.small for production
db_allocated_storage = 20                       # GiB
db_deletion_protection = false                  # Set true for production

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
- Push to `main` → GitHub Actions builds and pushes the normal image plus
  `lambda-latest` to ECR. Lambda functions use the `lambda-latest` image tag.

**Manual dispatch from GitHub:**
Use the Overmind CI workflow or run `scripts/docker-publish-lambda-ecr.sh`
locally when you need to refresh the Lambda image outside a push.

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

1. Confirm `curl "$(terraform output -raw lambda_api_endpoint)/health"`.
2. Visit `https://batocera-swarm.com/`.
3. Create or log in as an Overlord user.
4. Generate a Drone token.
5. Log in again and confirm user and Drone token data persisted.
6. Confirm the public hostname resolves through API Gateway.

## Known Limitations & Next Steps

**Email verification and OAuth credentials:**
Overmind sends production email through SMTP when `EMAIL_PROVIDER=smtp`. The runtime environment is stored in the single secret `bff-overmind/prod/runtime` by default (`${project_name}/${environment}/runtime`).

1. Keep the Purelymail TXT, MX, DKIM, SPF, and DMARC records in `route53_mail_records`.
2. Set `email_from_address` and `smtp_username` for the Purelymail mailbox in `terraform.tfvars`.
3. Store `SMTP_PASSWORD`, Google OAuth credentials, and GitHub OAuth credentials directly in `bff-overmind/prod/runtime`.

**Operator-managed runtime secret (`bff-overmind/prod/runtime`):**
Terraform creates this secret and seeds its initial payload for a new environment. After creation, its secret payload is operator-managed: Terraform ignores `secret_string` and secret-stage changes and prevents destruction of the runtime secret and its managed initial version. This protects hand-managed SMTP and OAuth values from being erased during `terraform apply`.

When adding or changing credentials, preserve every existing key in the JSON object, including database settings and `SECRET_KEY`. For example, retrieve the existing value, edit it locally with secure permissions, then write the complete updated object back:
```bash
umask 077
aws secretsmanager get-secret-value \
  --secret-id bff-overmind/prod/runtime \
  --query SecretString \
  --output text > /tmp/overmind-runtime.json

# Edit /tmp/overmind-runtime.json, retaining existing keys and adding:
# SMTP_PASSWORD, GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET,
# GITHUB_CLIENT_ID, GITHUB_CLIENT_SECRET, EMAIL_FROM_DISPLAY_NAME

aws secretsmanager put-secret-value \
  --secret-id bff-overmind/prod/runtime \
  --secret-string file:///tmp/overmind-runtime.json
rm -f /tmp/overmind-runtime.json
```

Every key in this JSON object is loaded into the container environment and also applied as a runtime override inside the app. Values are never logged. Overmind polls the same secret every `runtime_secret_refresh_seconds` seconds, applies changed runtime-read settings such as SMTP/email configuration, and keeps the last known good values if refresh fails. OAuth availability is also read from environment variables; changes are best confirmed after a container restart.

Because Terraform no longer updates the existing secret payload, changes to Terraform inputs represented in that JSON object, including regenerated database credentials, must also be applied deliberately to the secret during maintenance.

**RDS burstable instance:**
`db.t3.micro` is appropriate for development. For production traffic, upgrade to `db.t3.small` or `db.t3.medium` and set `db_deletion_protection = true`.

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

- API Gateway HTTP API requests and Lambda invocations/duration.
- RDS PostgreSQL `db.t3.micro` and 20 GiB storage.
- Route 53 hosted zone if one exists or is created elsewhere.
- ECR image storage after free allowances.
- Data transfer and CloudWatch logs.

This stack intentionally avoids EC2, NAT Gateway, ALB, ECS/Fargate, and Multi-AZ
RDS by default.

## Architecture Choices

The compute target is API Gateway + Lambda. Terraform creates separate Lambda
functions for low, medium, and high-cost endpoint groups from the same ECR image.

Public browser TLS is provided by API Gateway custom domains and ACM. ACM
certificate DNS validation records are also managed when
`create_acm_validation_records = true`.

The optional `enable_internal_ca_secret` variable creates a separate private CA secret for future Drone trust workflows. That private key is stored in Secrets Manager and Terraform state, so leave it disabled unless the application explicitly needs Terraform-created internal CA material.
