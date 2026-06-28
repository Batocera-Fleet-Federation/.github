# Edge service: always-on ECS Fargate task fronted by a Network Load Balancer.
#
# Terminates the drones' persistent outbound mux (TLS) and relays transfers. The
# REST/Lambda stack is unchanged; this adds the always-on compute Lambda can't be.
# Everything is gated on var.enable_edge so the stack is a no-op until you opt in.
#
# DRAFT: authored to match the existing main.tf patterns, but run `terraform plan`
# before applying -- it has not been plan-validated. Scope is mux (TCP) + relay;
# the STUN/UDP listener for hole punching is a follow-up (EDGE_STUN_PORT=0 here,
# so drones simply fall back to the relay), and CI/ECR image publishing for the
# edge image must be wired separately.

locals {
  edge_enabled = var.enable_edge
  edge_fqdn    = "${var.edge_subdomain}.${local.root_domain}"
  edge_name    = "${var.project_name}-${var.environment}-edge"
  edge_image   = local.edge_enabled ? "${aws_ecr_repository.edge[0].repository_url}:${var.edge_image_tag}" : ""
}

resource "aws_ecr_repository" "edge" {
  count                = local.edge_enabled ? 1 : 0
  name                 = "batocera-edge"
  image_tag_mutability = "MUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_cloudwatch_log_group" "edge" {
  count             = local.edge_enabled ? 1 : 0
  name              = "/ecs/${local.edge_name}"
  retention_in_days = 14
}

# ── Networking ───────────────────────────────────────────────────────────────
resource "aws_security_group" "edge" {
  count       = local.edge_enabled ? 1 : 0
  name        = local.edge_name
  description = "Edge mux/relay tasks"
  vpc_id      = aws_vpc.overmind.id

  ingress {
    description = "Drone mux (TLS terminated at the NLB, plain TCP to the task)"
    from_port   = 9443
    to_port     = 9443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group_rule" "db_from_edge" {
  count                    = local.edge_enabled ? 1 : 0
  type                     = "ingress"
  description              = "Postgres from Edge"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.db.id
  source_security_group_id = aws_security_group.edge[0].id
}

resource "aws_security_group_rule" "elasticache_from_edge" {
  count                    = local.edge_enabled && var.enable_elasticache ? 1 : 0
  type                     = "ingress"
  description              = "Redis from Edge"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  security_group_id        = aws_security_group.elasticache[0].id
  source_security_group_id = aws_security_group.edge[0].id
}

# ── TLS certificate for the edge subdomain ───────────────────────────────────
resource "aws_acm_certificate" "edge" {
  count             = local.edge_enabled ? 1 : 0
  domain_name       = local.edge_fqdn
  validation_method = "DNS"
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "edge_acm_validation" {
  for_each = local.edge_enabled ? {
    for dvo in aws_acm_certificate.edge[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  } : {}
  zone_id         = local.route53_zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "edge" {
  count                   = local.edge_enabled ? 1 : 0
  certificate_arn         = aws_acm_certificate.edge[0].arn
  validation_record_fqdns = [for record in aws_route53_record.edge_acm_validation : record.fqdn]
}

# ── Network Load Balancer (TLS -> task:9443) ─────────────────────────────────
resource "aws_lb" "edge" {
  count              = local.edge_enabled ? 1 : 0
  name               = local.edge_name
  load_balancer_type = "network"
  internal           = false
  subnets            = aws_subnet.public[*].id
}

resource "aws_lb_target_group" "edge_mux" {
  count       = local.edge_enabled ? 1 : 0
  name        = "${local.edge_name}-mux"
  port        = 9443
  protocol    = "TCP"
  target_type = "ip"
  vpc_id      = aws_vpc.overmind.id

  health_check {
    protocol = "TCP"
    port     = "9443"
  }
}

resource "aws_lb_listener" "edge_mux" {
  count             = local.edge_enabled ? 1 : 0
  load_balancer_arn = aws_lb.edge[0].arn
  port              = 443
  protocol          = "TLS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.edge[0].certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.edge_mux[0].arn
  }
}

resource "aws_route53_record" "edge" {
  count   = local.edge_enabled ? 1 : 0
  zone_id = local.route53_zone_id
  name    = local.edge_fqdn
  type    = "A"

  alias {
    name                   = aws_lb.edge[0].dns_name
    zone_id                = aws_lb.edge[0].zone_id
    evaluate_target_health = true
  }
}

# ── IAM ──────────────────────────────────────────────────────────────────────
resource "aws_iam_role" "edge_execution" {
  count = local.edge_enabled ? 1 : 0
  name  = "${local.edge_name}-execution"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "edge_execution" {
  count      = local.edge_enabled ? 1 : 0
  role       = aws_iam_role.edge_execution[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Lets the execution role inject DB creds + SECRET_KEY from the runtime secret.
resource "aws_iam_role_policy" "edge_secrets" {
  count = local.edge_enabled ? 1 : 0
  name  = "${local.edge_name}-secrets"
  role  = aws_iam_role.edge_execution[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [aws_secretsmanager_secret.overmind_runtime.arn]
    }]
  })
}

resource "aws_iam_role" "edge_task" {
  count = local.edge_enabled ? 1 : 0
  name  = "${local.edge_name}-task"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# ── ECS cluster / task / service ─────────────────────────────────────────────
resource "aws_ecs_cluster" "edge" {
  count = local.edge_enabled ? 1 : 0
  name  = local.edge_name
}

resource "aws_ecs_task_definition" "edge" {
  count                    = local.edge_enabled ? 1 : 0
  family                   = local.edge_name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.edge_cpu)
  memory                   = tostring(var.edge_memory)
  execution_role_arn       = aws_iam_role.edge_execution[0].arn
  task_role_arn            = aws_iam_role.edge_task[0].arn

  container_definitions = jsonencode([{
    name      = "edge"
    image     = local.edge_image
    essential = true
    portMappings = [{
      containerPort = 9443
      protocol      = "tcp"
    }]
    environment = concat([
      { name = "EDGE_HOST", value = "0.0.0.0" },
      { name = "EDGE_PORT", value = "9443" },
      # STUN/hole-punch needs a UDP NLB listener (follow-up); off for now so
      # drones fall back to the relay.
      { name = "EDGE_STUN_PORT", value = "0" },
      { name = "EDGE_AUTH", value = "db" },
      # NLB terminates TLS; the NLB->task hop is inside the VPC.
      { name = "EDGE_ALLOW_INSECURE", value = "1" },
      { name = "EDGE_NODE_ID", value = local.edge_name },
      { name = "OVERMIND_VERSION", value = var.overmind_version },
      ], var.enable_elasticache ? [
      { name = "OVERMIND_REDIS_URL", value = "redis://${aws_elasticache_cluster.overmind[0].cache_nodes[0].address}:6379" },
    ] : [])
    secrets = [
      { name = "OVERMIND_POSTGRES_HOST", valueFrom = "${aws_secretsmanager_secret.overmind_runtime.arn}:OVERMIND_POSTGRES_HOST::" },
      { name = "OVERMIND_POSTGRES_PORT", valueFrom = "${aws_secretsmanager_secret.overmind_runtime.arn}:OVERMIND_POSTGRES_PORT::" },
      { name = "OVERMIND_POSTGRES_DB", valueFrom = "${aws_secretsmanager_secret.overmind_runtime.arn}:OVERMIND_POSTGRES_DB::" },
      { name = "OVERMIND_POSTGRES_USER", valueFrom = "${aws_secretsmanager_secret.overmind_runtime.arn}:OVERMIND_POSTGRES_USER::" },
      { name = "OVERMIND_POSTGRES_PASSWORD", valueFrom = "${aws_secretsmanager_secret.overmind_runtime.arn}:OVERMIND_POSTGRES_PASSWORD::" },
      { name = "SECRET_KEY", valueFrom = "${aws_secretsmanager_secret.overmind_runtime.arn}:SECRET_KEY::" },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.edge[0].name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "edge"
      }
    }
  }])
}

resource "aws_ecs_service" "edge" {
  count           = local.edge_enabled ? 1 : 0
  name            = local.edge_name
  cluster         = aws_ecs_cluster.edge[0].id
  task_definition = aws_ecs_task_definition.edge[0].arn
  desired_count   = var.edge_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.edge[0].id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.edge_mux[0].arn
    container_name   = "edge"
    container_port   = 9443
  }

  depends_on = [aws_lb_listener.edge_mux]
}
