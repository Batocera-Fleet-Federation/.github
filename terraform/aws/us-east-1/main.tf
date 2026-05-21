data "aws_availability_zones" "available" {
  count = length(var.availability_zones) == 0 ? 1 : 0
  state = "available"
}

data "aws_caller_identity" "current" {}

data "aws_ami" "amazon_linux_2023" {
  count       = var.ami_id == "" ? 1 : 0
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_route53_zone" "selected" {
  count        = var.create_hosted_zone || var.hosted_zone_id != "" ? 0 : 1
  name         = var.hosted_zone_name
  private_zone = false
}

locals {
  root_domain              = trimsuffix(var.domain_name, ".")
  computed_overmind_domain = var.overmind_subdomain == "" ? local.root_domain : "${var.overmind_subdomain}.${local.root_domain}"
  overmind_fqdn            = var.overmind_domain_name == "" ? local.computed_overmind_domain : trimsuffix(var.overmind_domain_name, ".")
  www_domain               = "www.${local.root_domain}"
  availability_zones       = length(var.availability_zones) == 0 ? data.aws_availability_zones.available[0].names : var.availability_zones
  instance_ami_id          = var.ami_id == "" ? data.aws_ami.amazon_linux_2023[0].id : var.ami_id
  route53_zone_id          = var.create_hosted_zone ? aws_route53_zone.domain[0].zone_id : (var.hosted_zone_id != "" ? var.hosted_zone_id : data.aws_route53_zone.selected[0].zone_id)
  certificate_sans = distinct(compact(concat(
    [local.www_domain, local.overmind_fqdn == local.root_domain ? "" : local.overmind_fqdn],
    var.certificate_sans
  )))
}

resource "aws_route53_zone" "domain" {
  count = var.create_hosted_zone ? 1 : 0
  name  = local.root_domain
}

resource "aws_acm_certificate" "domain" {
  domain_name               = local.root_domain
  subject_alternative_names = local.certificate_sans
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "acm_validation" {
  for_each = var.create_acm_validation_records ? {
    for option in aws_acm_certificate.domain.domain_validation_options : option.domain_name => {
      name   = option.resource_record_name
      record = option.resource_record_value
      type   = option.resource_record_type
    }
  } : {}

  zone_id = local.route53_zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 300
  records = [each.value.record]
}

resource "aws_acm_certificate_validation" "domain" {
  count                   = var.create_acm_validation_records ? 1 : 0
  certificate_arn         = aws_acm_certificate.domain.arn
  validation_record_fqdns = [for record in aws_route53_record.acm_validation : record.fqdn]
}

resource "aws_ecr_repository" "overmind" {
  name                 = var.ecr_repository_name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "overmind" {
  repository = aws_ecr_repository.overmind.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Retain only the newest ${var.ecr_max_image_count} images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = var.ecr_max_image_count
      }
      action = { type = "expire" }
    }]
  })
}

resource "aws_vpc" "overmind" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
}

resource "aws_internet_gateway" "overmind" {
  vpc_id = aws_vpc.overmind.id
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.overmind.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = local.availability_zones[count.index]
  map_public_ip_on_launch = true
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.overmind.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.overmind.id
  }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "app" {
  name        = "${var.project_name}-${var.environment}-app"
  description = "Public HTTPS and ACME ingress for Overmind"
  vpc_id      = aws_vpc.overmind.id

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP for ACME and redirect"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  dynamic "ingress" {
    for_each = var.admin_ssh_cidr == "" ? [] : [var.admin_ssh_cidr]
    content {
      description = "SSH admin"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "db" {
  name        = "${var.project_name}-${var.environment}-db"
  description = "PostgreSQL only from Overmind app"
  vpc_id      = aws_vpc.overmind.id

  ingress {
    description     = "PostgreSQL from app"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "random_password" "db_password" {
  length  = 32
  special = true
}

resource "random_password" "secret_key" {
  length  = 48
  special = false
}

resource "aws_db_subnet_group" "overmind" {
  name       = "${var.project_name}-${var.environment}"
  subnet_ids = aws_subnet.public[*].id
}

resource "aws_db_instance" "overmind" {
  identifier                   = "${var.project_name}-${var.environment}"
  engine                       = "postgres"
  engine_version               = var.db_engine_version
  instance_class               = var.db_instance_class
  allocated_storage            = var.db_allocated_storage
  db_name                      = var.db_name
  username                     = var.db_username
  password                     = random_password.db_password.result
  db_subnet_group_name         = aws_db_subnet_group.overmind.name
  vpc_security_group_ids       = [aws_security_group.db.id]
  publicly_accessible          = false
  multi_az                     = false
  storage_encrypted            = true
  deletion_protection          = var.db_deletion_protection
  skip_final_snapshot          = var.db_skip_final_snapshot
  backup_retention_period      = 1
  auto_minor_version_upgrade   = true
  performance_insights_enabled = false
}

resource "aws_secretsmanager_secret" "overmind_runtime" {
  name                    = "${var.project_name}/${var.environment}/runtime"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "overmind_runtime" {
  secret_id = aws_secretsmanager_secret.overmind_runtime.id
  secret_string = jsonencode({
    OVERMIND_POSTGRES_HOST     = aws_db_instance.overmind.address
    OVERMIND_POSTGRES_PORT     = tostring(aws_db_instance.overmind.port)
    OVERMIND_POSTGRES_DB       = var.db_name
    OVERMIND_POSTGRES_USER     = var.db_username
    OVERMIND_POSTGRES_PASSWORD = random_password.db_password.result
    SECRET_KEY                 = random_password.secret_key.result
  })
}

resource "tls_private_key" "internal_ca" {
  count     = var.enable_internal_ca_secret ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_self_signed_cert" "internal_ca" {
  count                 = var.enable_internal_ca_secret ? 1 : 0
  private_key_pem       = tls_private_key.internal_ca[0].private_key_pem
  is_ca_certificate     = true
  validity_period_hours = 87600

  subject {
    common_name  = "${var.project_name}-${var.environment}-drone-trust-ca"
    organization = "Batocera Fleet Federation"
  }

  allowed_uses = ["cert_signing", "crl_signing", "digital_signature"]
}

resource "aws_secretsmanager_secret" "internal_ca" {
  count                   = var.enable_internal_ca_secret ? 1 : 0
  name                    = "${var.project_name}/${var.environment}/internal-ca"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "internal_ca" {
  count     = var.enable_internal_ca_secret ? 1 : 0
  secret_id = aws_secretsmanager_secret.internal_ca[0].id
  secret_string = jsonencode({
    ca_certificate_pem = tls_self_signed_cert.internal_ca[0].cert_pem
    ca_private_key_pem = tls_private_key.internal_ca[0].private_key_pem
  })
}

resource "aws_iam_role" "instance" {
  name = "${var.project_name}-${var.environment}-instance"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "instance" {
  name = "${var.project_name}-${var.environment}-runtime"
  role = aws_iam_role.instance.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = compact([aws_secretsmanager_secret.overmind_runtime.arn, var.enable_internal_ca_secret ? aws_secretsmanager_secret.internal_ca[0].arn : ""])
      }
    ]
  })
}

resource "aws_iam_instance_profile" "overmind" {
  name = "${var.project_name}-${var.environment}"
  role = aws_iam_role.instance.name
}

locals {
  image_latest = "${aws_ecr_repository.overmind.repository_url}:latest"
  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    aws_region              = var.aws_region
    ecr_repository_url      = aws_ecr_repository.overmind.repository_url
    ecr_registry_url        = split("/", aws_ecr_repository.overmind.repository_url)[0]
    image                   = local.image_latest
    domain_name             = local.overmind_fqdn
    runtime_secret_id       = aws_secretsmanager_secret.overmind_runtime.arn
    internal_ca_secret_id   = var.enable_internal_ca_secret ? aws_secretsmanager_secret.internal_ca[0].arn : ""
    overmind_container_port = var.overmind_container_port
    environment             = var.environment
  })
}

resource "aws_instance" "overmind" {
  ami                         = local.instance_ami_id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public[0].id
  vpc_security_group_ids      = [aws_security_group.app.id]
  iam_instance_profile        = aws_iam_instance_profile.overmind.name
  associate_public_ip_address = true
  key_name                    = var.ssh_key_name == "" ? null : var.ssh_key_name
  user_data_replace_on_change = true
  user_data                   = local.user_data

  root_block_device {
    volume_type = "gp3"
    volume_size = 12
    encrypted   = true
  }
}

resource "aws_eip" "overmind" {
  domain = "vpc"
}

resource "aws_eip_association" "overmind" {
  instance_id   = aws_instance.overmind.id
  allocation_id = aws_eip.overmind.id
}

resource "aws_route53_record" "overmind" {
  count   = var.create_route53_record ? 1 : 0
  zone_id = local.route53_zone_id
  name    = local.overmind_fqdn
  type    = "A"
  ttl     = 300
  records = [aws_eip.overmind.public_ip]
}

resource "aws_route53_record" "apex" {
  count   = var.create_route53_record && local.overmind_fqdn != local.root_domain ? 1 : 0
  zone_id = local.route53_zone_id
  name    = local.root_domain
  type    = "A"
  ttl     = 300
  records = [aws_eip.overmind.public_ip]
}

resource "aws_route53_record" "www" {
  count   = var.create_route53_record ? 1 : 0
  zone_id = local.route53_zone_id
  name    = local.www_domain
  type    = "A"
  ttl     = 300
  records = [aws_eip.overmind.public_ip]
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = var.github_oidc_thumbprints
}

resource "aws_iam_role" "github_deploy" {
  name = "${var.project_name}-${var.environment}-github-deploy"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/${var.github_branch}"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_deploy" {
  name = "${var.project_name}-${var.environment}-github-deploy"
  role = aws_iam_role.github_deploy.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:BatchGetImage",
          "ecr:DescribeRepositories"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:SendCommand",
          "ssm:GetCommandInvocation",
          "ssm:ListCommandInvocations",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceStatus"
        ]
        Resource = "*"
      }
    ]
  })
}
