data "aws_availability_zones" "available" {
  count = length(var.availability_zones) == 0 ? 1 : 0
  state = "available"
}

data "aws_caller_identity" "current" {}

data "aws_route53_zone" "selected" {
  count        = var.create_hosted_zone || var.hosted_zone_id != "" ? 0 : 1
  name         = var.hosted_zone_name
  private_zone = false
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

resource "aws_route53_record" "mail" {
  for_each = var.route53_mail_records

  zone_id         = local.route53_zone_id
  allow_overwrite = true
  name            = each.value.name == "" ? local.root_domain : each.value.name
  type            = upper(each.value.type)
  ttl             = each.value.ttl
  records         = each.value.records
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
  # Create up to 2 public subnets, but don't exceed the number of available AZs
  count                   = min(2, length(local.availability_zones))
  vpc_id                  = aws_vpc.overmind.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = local.availability_zones[count.index]
  map_public_ip_on_launch = true
}

resource "aws_subnet" "private" {
  count             = var.lambda_create_nat_gateway ? min(2, length(local.availability_zones)) : 0
  vpc_id            = aws_vpc.overmind.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = local.availability_zones[count.index]
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

resource "aws_eip" "nat" {
  count  = var.lambda_create_nat_gateway ? 1 : 0
  domain = "vpc"
}

resource "aws_nat_gateway" "lambda" {
  count         = var.lambda_create_nat_gateway ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id

  depends_on = [aws_internet_gateway.overmind]
}

resource "aws_route_table" "private" {
  count  = var.lambda_create_nat_gateway ? 1 : 0
  vpc_id = aws_vpc.overmind.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.lambda[0].id
  }
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[0].id
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

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    ignore_changes = [ingress]
  }
}

resource "aws_security_group" "lambda" {
  count       = local.lambda_enabled ? 1 : 0
  name        = "${var.project_name}-${var.environment}-lambda"
  description = "Lambda runtime egress for serverless Overmind"
  vpc_id      = aws_vpc.overmind.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "rds_proxy" {
  count       = local.rds_proxy_enabled ? 1 : 0
  name        = "${var.project_name}-${var.environment}-rds-proxy"
  description = "RDS Proxy access from Overmind Lambda functions"
  vpc_id      = aws_vpc.overmind.id

  ingress {
    description     = "PostgreSQL from Lambda"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda[0].id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group_rule" "db_from_rds_proxy" {
  count                    = local.rds_proxy_enabled ? 1 : 0
  type                     = "ingress"
  description              = "PostgreSQL from RDS Proxy"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.db.id
  source_security_group_id = aws_security_group.rds_proxy[0].id
}

resource "aws_security_group_rule" "db_from_lambda_direct" {
  count                    = local.lambda_enabled && !var.enable_rds_proxy ? 1 : 0
  type                     = "ingress"
  description              = "PostgreSQL directly from Lambda when RDS Proxy is disabled"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.db.id
  source_security_group_id = aws_security_group.lambda[0].id
}

resource "aws_security_group" "vpc_endpoints" {
  count       = local.lambda_enabled ? 1 : 0
  name        = "${var.project_name}-${var.environment}-vpc-endpoints"
  description = "Interface endpoint access from Overmind Lambda functions"
  vpc_id      = aws_vpc.overmind.id

  ingress {
    description     = "HTTPS from Lambda"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda[0].id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "random_password" "db_password" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
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

resource "aws_vpc_endpoint" "secretsmanager" {
  count               = local.lambda_enabled ? 1 : 0
  vpc_id              = aws_vpc.overmind.id
  service_name        = "com.amazonaws.${var.aws_region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.lambda_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true
}

resource "aws_secretsmanager_secret" "db_credentials" {
  count                   = local.rds_proxy_enabled ? 1 : 0
  name                    = "${var.project_name}/${var.environment}/db-credentials"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  count     = local.rds_proxy_enabled ? 1 : 0
  secret_id = aws_secretsmanager_secret.db_credentials[0].id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db_password.result
  })
}

resource "aws_iam_role" "rds_proxy" {
  count = local.rds_proxy_enabled ? 1 : 0
  name  = "${var.project_name}-${var.environment}-rds-proxy"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "rds_proxy" {
  count = local.rds_proxy_enabled ? 1 : 0
  name  = "${var.project_name}-${var.environment}-rds-proxy"
  role  = aws_iam_role.rds_proxy[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = aws_secretsmanager_secret.db_credentials[0].arn
    }]
  })
}

resource "aws_db_proxy" "overmind" {
  count                  = local.rds_proxy_enabled ? 1 : 0
  name                   = "${var.project_name}-${var.environment}"
  debug_logging          = false
  engine_family          = "POSTGRESQL"
  idle_client_timeout    = 1800
  require_tls            = true
  role_arn               = aws_iam_role.rds_proxy[0].arn
  vpc_security_group_ids = [aws_security_group.rds_proxy[0].id]
  vpc_subnet_ids         = aws_subnet.public[*].id

  auth {
    auth_scheme = "SECRETS"
    iam_auth    = "DISABLED"
    secret_arn  = aws_secretsmanager_secret.db_credentials[0].arn
  }
}

resource "aws_db_proxy_default_target_group" "overmind" {
  count         = local.rds_proxy_enabled ? 1 : 0
  db_proxy_name = aws_db_proxy.overmind[0].name

  connection_pool_config {
    connection_borrow_timeout    = 120
    max_connections_percent      = 80
    max_idle_connections_percent = 50
  }
}

resource "aws_db_proxy_target" "overmind" {
  count                  = local.rds_proxy_enabled ? 1 : 0
  db_instance_identifier = aws_db_instance.overmind.identifier
  db_proxy_name          = aws_db_proxy.overmind[0].name
  target_group_name      = aws_db_proxy_default_target_group.overmind[0].name
}

resource "aws_secretsmanager_secret" "overmind_runtime" {
  name                    = "${var.project_name}/${var.environment}/runtime"
  recovery_window_in_days = 0

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_secretsmanager_secret_version" "overmind_runtime" {
  secret_id = aws_secretsmanager_secret.overmind_runtime.id
  secret_string = jsonencode(merge({
    OVERMIND_POSTGRES_HOST          = aws_db_instance.overmind.address
    OVERMIND_POSTGRES_PORT          = tostring(aws_db_instance.overmind.port)
    OVERMIND_POSTGRES_DB            = var.db_name
    OVERMIND_POSTGRES_USER          = var.db_username
    OVERMIND_POSTGRES_PASSWORD      = random_password.db_password.result
    SECRET_KEY                      = random_password.secret_key.result
    AWS_REGION                      = var.aws_region
    EMAIL_PROVIDER                  = var.email_provider
    EMAIL_FROM                      = local.email_from_address
    SMTP_HOST                       = var.smtp_host
    SMTP_PORT                       = tostring(var.smtp_port)
    SMTP_USERNAME                   = var.smtp_username
    SMTP_STARTTLS                   = tostring(var.smtp_starttls)
    OVERMIND_RUNTIME_SECRET_NAME    = aws_secretsmanager_secret.overmind_runtime.name
    OVERMIND_SECRET_REFRESH_SECONDS = tostring(var.runtime_secret_refresh_seconds)
  }, var.runtime_secret_extra_env))

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [secret_string, version_stages]
  }
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

resource "aws_route53_record" "overmind" {
  count           = var.create_route53_record && local.lambda_enabled && local.overmind_fqdn != local.www_domain ? 1 : 0
  zone_id         = local.route53_zone_id
  allow_overwrite = true
  name            = local.overmind_fqdn
  type            = "A"

  alias {
    name                   = aws_apigatewayv2_domain_name.overmind[local.overmind_fqdn].domain_name_configuration[0].target_domain_name
    zone_id                = aws_apigatewayv2_domain_name.overmind[local.overmind_fqdn].domain_name_configuration[0].hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "apex" {
  count           = var.create_route53_record && local.lambda_enabled && local.overmind_fqdn != local.root_domain ? 1 : 0
  zone_id         = local.route53_zone_id
  allow_overwrite = true
  name            = local.root_domain
  type            = "A"

  alias {
    name                   = aws_apigatewayv2_domain_name.overmind[local.root_domain].domain_name_configuration[0].target_domain_name
    zone_id                = aws_apigatewayv2_domain_name.overmind[local.root_domain].domain_name_configuration[0].hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "www" {
  count           = var.create_route53_record && local.lambda_enabled && local.overmind_fqdn != local.www_domain ? 1 : 0
  zone_id         = local.route53_zone_id
  allow_overwrite = true
  name            = local.www_domain
  type            = "A"

  alias {
    name                   = aws_apigatewayv2_domain_name.overmind[local.www_domain].domain_name_configuration[0].target_domain_name
    zone_id                = aws_apigatewayv2_domain_name.overmind[local.www_domain].domain_name_configuration[0].hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "primary" {
  count           = var.create_route53_record && local.lambda_enabled && local.overmind_fqdn == local.www_domain ? 1 : 0
  zone_id         = local.route53_zone_id
  allow_overwrite = true
  name            = local.www_domain
  type            = "A"

  alias {
    name                   = aws_apigatewayv2_domain_name.overmind[local.www_domain].domain_name_configuration[0].target_domain_name
    zone_id                = aws_apigatewayv2_domain_name.overmind[local.www_domain].domain_name_configuration[0].hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_cloudwatch_log_group" "lambda" {
  for_each          = local.lambda_enabled ? merge(local.lambda_function_tiers, { scheduled = local.lambda_function_tiers.medium }) : {}
  name              = "/aws/lambda/${var.project_name}-${var.environment}-${each.key}"
  retention_in_days = var.lambda_log_retention_days
}

resource "aws_cloudwatch_log_group" "api_gateway" {
  count             = local.lambda_enabled ? 1 : 0
  name              = "/aws/apigateway/${var.project_name}-${var.environment}-overmind"
  retention_in_days = var.api_gateway_log_retention_days
}

resource "aws_iam_role" "lambda" {
  count = local.lambda_enabled ? 1 : 0
  name  = "${var.project_name}-${var.environment}-lambda"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "lambda" {
  count = local.lambda_enabled ? 1 : 0
  name  = "${var.project_name}-${var.environment}-lambda"
  role  = aws_iam_role.lambda[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = [
          for log_group in aws_cloudwatch_log_group.lambda : "${log_group.arn}:*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface",
          "ec2:AssignPrivateIpAddresses",
          "ec2:UnassignPrivateIpAddresses"
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

resource "aws_lambda_function" "api" {
  for_each                       = local.lambda_enabled ? local.lambda_function_tiers : {}
  function_name                  = "${var.project_name}-${var.environment}-${each.key}"
  role                           = aws_iam_role.lambda[0].arn
  package_type                   = "Image"
  image_uri                      = local.lambda_image
  architectures                  = var.lambda_architectures
  memory_size                    = each.value.memory
  timeout                        = each.value.timeout
  reserved_concurrent_executions = var.lambda_reserved_concurrency

  image_config {
    command = ["overmind.lambda_handler.handler"]
  }

  environment {
    variables = merge({
      OVERMIND_ENVIRONMENT            = var.environment
      OVERMIND_RUNTIME                = "lambda"
      OVERMIND_RUNTIME_SECRET_NAME    = aws_secretsmanager_secret.overmind_runtime.name
      OVERMIND_POSTGRES_HOST_OVERRIDE = local.lambda_db_host
      JWT_SIGNING_SECRET              = random_password.secret_key.result
      OVERMIND_VERSION                = var.overmind_version
      USE_FAKE_DATA                   = tostring(var.use_fake_data)
      }, var.enable_internal_ca_secret ? {
      OVERMIND_INTERNAL_CA_SECRET_NAME = aws_secretsmanager_secret.internal_ca[0].name
    } : {})
  }

  vpc_config {
    subnet_ids         = local.lambda_subnet_ids
    security_group_ids = [aws_security_group.lambda[0].id]
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_db_proxy_target.overmind,
    aws_vpc_endpoint.secretsmanager
  ]
}

resource "aws_lambda_function" "scheduled" {
  count         = local.lambda_enabled ? 1 : 0
  function_name = "${var.project_name}-${var.environment}-scheduled"
  role          = aws_iam_role.lambda[0].arn
  package_type  = "Image"
  image_uri     = local.lambda_image
  architectures = var.lambda_architectures
  memory_size   = var.lambda_medium_memory_mb
  timeout       = 300

  image_config {
    command = ["overmind.lambda_handler.scheduled_handler"]
  }

  environment {
    variables = merge({
      OVERMIND_ENVIRONMENT            = var.environment
      OVERMIND_RUNTIME                = "lambda"
      OVERMIND_RUNTIME_SECRET_NAME    = aws_secretsmanager_secret.overmind_runtime.name
      OVERMIND_POSTGRES_HOST_OVERRIDE = local.lambda_db_host
      JWT_SIGNING_SECRET              = random_password.secret_key.result
      OVERMIND_VERSION                = var.overmind_version
      USE_FAKE_DATA                   = tostring(var.use_fake_data)
      }, var.enable_internal_ca_secret ? {
      OVERMIND_INTERNAL_CA_SECRET_NAME = aws_secretsmanager_secret.internal_ca[0].name
    } : {})
  }

  vpc_config {
    subnet_ids         = local.lambda_subnet_ids
    security_group_ids = [aws_security_group.lambda[0].id]
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_db_proxy_target.overmind,
    aws_vpc_endpoint.secretsmanager
  ]
}

resource "aws_apigatewayv2_api" "overmind" {
  count         = local.lambda_enabled ? 1 : 0
  name          = "${var.project_name}-${var.environment}"
  protocol_type = "HTTP"

  cors_configuration {
    allow_headers = ["*"]
    allow_methods = ["*"]
    allow_origins = var.lambda_cors_allowed_origins
  }
}

resource "aws_apigatewayv2_integration" "lambda" {
  for_each               = local.lambda_enabled ? local.lambda_function_tiers : {}
  api_id                 = aws_apigatewayv2_api.overmind[0].id
  integration_type       = "AWS_PROXY"
  integration_method     = "POST"
  integration_uri        = aws_lambda_function.api[each.key].invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "default" {
  count     = local.lambda_enabled ? 1 : 0
  api_id    = aws_apigatewayv2_api.overmind[0].id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.lambda["low"].id}"
}

resource "aws_apigatewayv2_route" "tiered" {
  for_each  = local.lambda_enabled ? local.lambda_routes : {}
  api_id    = aws_apigatewayv2_api.overmind[0].id
  route_key = each.key
  target    = "integrations/${aws_apigatewayv2_integration.lambda[each.value].id}"
}

resource "aws_apigatewayv2_stage" "default" {
  count       = local.lambda_enabled ? 1 : 0
  api_id      = aws_apigatewayv2_api.overmind[0].id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gateway[0].arn
    format = jsonencode({
      requestId        = "$context.requestId"
      ip               = "$context.identity.sourceIp"
      requestTime      = "$context.requestTime"
      httpMethod       = "$context.httpMethod"
      routeKey         = "$context.routeKey"
      status           = "$context.status"
      protocol         = "$context.protocol"
      responseLength   = "$context.responseLength"
      integrationError = "$context.integrationErrorMessage"
    })
  }
}

resource "aws_apigatewayv2_domain_name" "overmind" {
  for_each    = local.api_custom_domains
  domain_name = each.value

  domain_name_configuration {
    certificate_arn = aws_acm_certificate.domain.arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }

  depends_on = [aws_acm_certificate_validation.domain]
}

resource "aws_apigatewayv2_api_mapping" "overmind" {
  for_each    = local.api_custom_domains
  api_id      = aws_apigatewayv2_api.overmind[0].id
  domain_name = aws_apigatewayv2_domain_name.overmind[each.value].id
  stage       = aws_apigatewayv2_stage.default[0].id
}

resource "aws_lambda_permission" "api_gateway" {
  for_each      = local.lambda_enabled ? local.lambda_function_tiers : {}
  statement_id  = "AllowExecutionFromApiGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api[each.key].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.overmind[0].execution_arn}/*/*"
}

resource "aws_cloudwatch_event_rule" "scheduled" {
  for_each            = local.lambda_enabled ? local.scheduled_jobs : {}
  name                = "${var.project_name}-${var.environment}-${each.key}"
  description         = "Run Overmind ${each.key} maintenance job"
  schedule_expression = each.value
}

resource "aws_cloudwatch_event_target" "scheduled" {
  for_each = local.lambda_enabled ? local.scheduled_jobs : {}
  rule     = aws_cloudwatch_event_rule.scheduled[each.key].name
  arn      = aws_lambda_function.scheduled[0].arn
  input    = jsonencode({ job = each.key })
}

resource "aws_lambda_permission" "eventbridge" {
  for_each      = local.lambda_enabled ? local.scheduled_jobs : {}
  statement_id  = "AllowExecutionFromEventBridge-${replace(each.key, "-", "")}"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.scheduled[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.scheduled[each.key].arn
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  for_each            = local.lambda_enabled ? merge(local.lambda_function_tiers, { scheduled = local.lambda_function_tiers.medium }) : {}
  alarm_name          = "${var.project_name}-${var.environment}-${each.key}-lambda-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = each.key == "scheduled" ? aws_lambda_function.scheduled[0].function_name : aws_lambda_function.api[each.key].function_name
  }
}

resource "aws_cloudwatch_metric_alarm" "lambda_duration" {
  for_each            = local.lambda_enabled ? local.lambda_function_tiers : {}
  alarm_name          = "${var.project_name}-${var.environment}-${each.key}-lambda-duration"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "Duration"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Average"
  threshold           = each.value.timeout * 1000 * 0.8
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.api[each.key].function_name
  }
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
          "lambda:GetFunction",
          "lambda:UpdateFunctionCode",
          "lambda:UpdateFunctionConfiguration"
        ]
        Resource = local.lambda_enabled ? concat(
          [for function in aws_lambda_function.api : function.arn],
          [aws_lambda_function.scheduled[0].arn]
        ) : []
      }
    ]
  })
}
