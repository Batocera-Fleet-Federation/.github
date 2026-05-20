# Batocera Overmind on AWS, us-east-1

This Terraform stack deploys Overmind on low-cost AWS infrastructure:

- Amazon ECR repository for the Overmind image.
- One Amazon Linux 2023 EC2 instance running Docker.
- Caddy in Docker for public HTTPS and automatic Let's Encrypt certificates.
- Private RDS PostgreSQL, reachable only from the Overmind instance security group.
- AWS Secrets Manager for database credentials and `SECRET_KEY`.
- SSM Session Manager/Run Command for deployment, so SSH can stay disabled.
- GitHub Actions OIDC role for image push and SSM deployment.

The default public hostname is `overmind.theoutlawoasis.com`. This stack does **not** manage `www.theoutlawoasis.com` or the apex record. Keep `create_route53_record = false` if DNS for `theoutlawoasis.com` is managed by another Terraform state.

## Architecture Choice

The initial compute target is EC2 + Docker instead of ECS/Fargate + ALB. That keeps the resource list small and avoids always-on ALB and NAT Gateway costs. HTTPS is handled by Caddy with Let's Encrypt because ACM public certificates cannot be exported and attached directly to a process on EC2. If you later want ACM-managed certificates, add an ALB or CloudFront in front of the instance and accept that cost.

## Public TLS vs Internal Drone CA

Public browser TLS is provided by Caddy/Let's Encrypt for `overmind.theoutlawoasis.com`.

The optional `enable_internal_ca_secret` variable creates a separate private CA secret for future Drone trust workflows. That private key is stored in Secrets Manager and Terraform state, so leave it disabled unless the application explicitly needs Terraform-created internal CA material.

## Setup

Copy the example variables:

```bash
cd .github/terraform/aws/us-east-1
cp terraform.tfvars.example terraform.tfvars
```

Edit at least:

```hcl
github_org  = "Batocera-Fleet-Federation"
github_repo = "batocera.overmind"
```

Leave this disabled unless this state should create the subdomain record:

```hcl
create_route53_record = false
```

Deploy:

```bash
terraform init
terraform fmt
terraform validate
terraform plan
terraform apply
```

If `create_route53_record = false`, create the DNS record shown by:

```bash
terraform output manual_dns_record
```

It will be an `A` record for `overmind.theoutlawoasis.com` pointing at the instance Elastic IP.

## GitHub Actions Variables

Set these repository variables in `batocera.overmind`, which owns `.github/workflows/deploy-overmind-aws.yml`:

- `AWS_REGION`: `us-east-1`
- `AWS_ROLE_TO_ASSUME`: value of `terraform output github_actions_role_arn`
- `ECR_REPOSITORY`: `batocera-overmind`
- `OVERMIND_ENVIRONMENT`: `prod`
- `OVERMIND_PROJECT_NAME`: `bff-overmind`

No long-lived AWS keys are required. The workflow uses GitHub OIDC to assume the deploy role.

## Deployment Flow

The workflow:

1. Checks out `batocera.overmind`.
2. Builds the Overmind Docker image.
3. Pushes tags `${git_sha}` and `latest` to ECR.
4. Finds the running EC2 instance by Terraform tags.
5. Uses SSM Run Command to run `/opt/overmind/deploy.sh <image>`.

Manual dispatch deploys the current branch/ref. Pushes to Overmind application or Docker files on `main` also deploy.

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
2. Visit `https://overmind.theoutlawoasis.com/`.
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
7. Confirm `https://www.theoutlawoasis.com` is unchanged.

## Cost Notes

Cost-impacting resources:

- EC2 `t3.micro` instance and public IPv4/Elastic IP.
- RDS PostgreSQL `db.t3.micro` and 20 GiB storage.
- Route 53 hosted zone if one exists or is created elsewhere.
- ECR image storage after free allowances.
- Data transfer and CloudWatch/SSM operational logs.

This stack intentionally avoids NAT Gateway, ALB, ECS/Fargate, and Multi-AZ RDS by default.

## Limitations

- Caddy uses Let's Encrypt rather than ACM because there is no ALB/CloudFront in this low-cost design.
- The GitHub OIDC provider is created in this state. If your AWS account already has a GitHub OIDC provider, import it or refactor this stack to reference the existing provider.
- RDS is in private mode by `publicly_accessible=false` and security group isolation, but the subnets have internet routes to avoid NAT Gateway cost.
