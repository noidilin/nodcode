data "aws_caller_identity" "current" {}

data "aws_route53_zone" "selected" {
  name         = var.hosted_zone_name
  private_zone = false
}

data "aws_iam_policy_document" "ecs_tasks_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

locals {
  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terragrunt"
    Owner       = var.owner
  }

  runtime_boundary_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/lab-devops-permissions-boundary"

  bedrock_model_arn = "arn:aws:bedrock:${var.bedrock_region}::foundation-model/${var.bedrock_chat_model_id}"
  bedrock_model_arns = distinct(concat(
    [local.bedrock_model_arn],
    var.additional_bedrock_model_arns,
  ))
}

resource "aws_secretsmanager_secret" "app" {
  name                    = "${var.name_prefix}/api-runtime"
  description             = "NodCode API runtime third-party secrets. Values are written out-of-band and must not be passed through Terraform."
  recovery_window_in_days = 7

  tags = local.common_tags
}

# Bootstrap a non-sensitive initial version so the first ECS service deployment can
# resolve all referenced JSON keys. Real third-party secret values are written
# out-of-band with aws secretsmanager put-secret-value and are ignored here.
resource "aws_secretsmanager_secret_version" "app_bootstrap" {
  secret_id = aws_secretsmanager_secret.app.id
  secret_string = jsonencode({
    CLERK_SECRET_KEY         = ""
    CLERK_PUBLISHABLE_KEY    = ""
    POLAR_ACCESS_TOKEN       = ""
    POLAR_PRODUCT_ID         = ""
    POLAR_CREDITS_METER_ID   = ""
    POLAR_SERVER             = "sandbox"
    SENTRY_DSN               = ""
    ANTHROPIC_API_KEY        = ""
    OPENAI_API_KEY           = ""
    AWS_BEARER_TOKEN_BEDROCK = ""
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/ecs/${var.name_prefix}-api"
  retention_in_days = var.log_retention_days

  tags = local.common_tags
}

resource "aws_ecs_cluster" "main" {
  name = "${var.name_prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-cluster" })
}

resource "aws_iam_role" "ecs_execution" {
  name                 = "${var.name_prefix}-ecs-execution"
  permissions_boundary = local.runtime_boundary_arn
  assume_role_policy   = data.aws_iam_policy_document.ecs_tasks_assume_role.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ecs_execution_managed" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "ecs_execution_secrets" {
  statement {
    sid     = "ReadInjectedRuntimeSecrets"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      aws_secretsmanager_secret.app.arn,
      var.database_secret_arn,
    ]
  }
}

resource "aws_iam_role_policy" "ecs_execution_secrets" {
  name   = "read-injected-runtime-secrets"
  role   = aws_iam_role.ecs_execution.id
  policy = data.aws_iam_policy_document.ecs_execution_secrets.json
}

resource "aws_iam_role" "ecs_task" {
  name                 = "${var.name_prefix}-ecs-task"
  permissions_boundary = local.runtime_boundary_arn
  assume_role_policy   = data.aws_iam_policy_document.ecs_tasks_assume_role.json

  tags = local.common_tags
}

data "aws_iam_policy_document" "ecs_task_phase1" {
  statement {
    sid = "InvokeApprovedBedrockModels"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]
    resources = local.bedrock_model_arns
  }
}

resource "aws_iam_role_policy" "ecs_task_phase1" {
  name   = "control-plane-application-permissions"
  role   = aws_iam_role.ecs_task.id
  policy = data.aws_iam_policy_document.ecs_task_phase1.json
}

resource "aws_ecs_task_definition" "api" {
  family                   = "${var.name_prefix}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.task_cpu)
  memory                   = tostring(var.task_memory)
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = "api"
      image     = "${var.ecr_repository_url}:${var.image_tag}"
      essential = true

      portMappings = [
        {
          containerPort = var.api_container_port
          hostPort      = var.api_container_port
          protocol      = "tcp"
        }
      ]

      environment = [
        { name = "NODE_ENV", value = "production" },
        { name = "HOST", value = "0.0.0.0" },
        { name = "PORT", value = tostring(var.api_container_port) },
        { name = "BEDROCK_AWS_REGION", value = var.bedrock_region },
        { name = "BEDROCK_CHAT_MODEL_ID", value = var.bedrock_chat_model_id }
      ]

      secrets = [
        { name = "DATABASE_URL", valueFrom = "${var.database_secret_arn}:DATABASE_URL::" },
        { name = "CLERK_SECRET_KEY", valueFrom = "${aws_secretsmanager_secret.app.arn}:CLERK_SECRET_KEY::" },
        { name = "CLERK_PUBLISHABLE_KEY", valueFrom = "${aws_secretsmanager_secret.app.arn}:CLERK_PUBLISHABLE_KEY::" },
        { name = "POLAR_ACCESS_TOKEN", valueFrom = "${aws_secretsmanager_secret.app.arn}:POLAR_ACCESS_TOKEN::" },
        { name = "POLAR_PRODUCT_ID", valueFrom = "${aws_secretsmanager_secret.app.arn}:POLAR_PRODUCT_ID::" },
        { name = "POLAR_CREDITS_METER_ID", valueFrom = "${aws_secretsmanager_secret.app.arn}:POLAR_CREDITS_METER_ID::" },
        { name = "POLAR_SERVER", valueFrom = "${aws_secretsmanager_secret.app.arn}:POLAR_SERVER::" },
        { name = "SENTRY_DSN", valueFrom = "${aws_secretsmanager_secret.app.arn}:SENTRY_DSN::" },
        { name = "ANTHROPIC_API_KEY", valueFrom = "${aws_secretsmanager_secret.app.arn}:ANTHROPIC_API_KEY::" },
        { name = "OPENAI_API_KEY", valueFrom = "${aws_secretsmanager_secret.app.arn}:OPENAI_API_KEY::" },
        { name = "AWS_BEARER_TOKEN_BEDROCK", valueFrom = "${aws_secretsmanager_secret.app.arn}:AWS_BEARER_TOKEN_BEDROCK::" }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.api.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "api"
          mode                  = "blocking"
        }
      }

      healthCheck = {
        command     = ["CMD-SHELL", "bun -e 'const r=await fetch(\"http://127.0.0.1:${var.api_container_port}${var.health_check_path}\"); if(!r.ok) process.exit(1)'"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 15
      }
    }
  ])
}

resource "aws_ecs_task_definition" "database_migration" {
  family                   = "${var.name_prefix}-database-migration"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.task_cpu)
  memory                   = tostring(var.task_memory)
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = "migration"
      image     = "${var.ecr_repository_url}:${var.image_tag}"
      essential = true
      command   = ["bun", "run", "--cwd", "packages/database", "db:migrate:deploy"]

      environment = [
        { name = "NODE_ENV", value = "production" }
      ]

      secrets = [
        { name = "DATABASE_URL", valueFrom = "${var.database_secret_arn}:DATABASE_URL::" }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.api.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "migration"
          mode                  = "blocking"
        }
      }
    }
  ])
}

resource "aws_acm_certificate" "api" {
  domain_name       = var.api_domain
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = local.common_tags
}

resource "aws_route53_record" "api_certificate_validation" {
  for_each = {
    for dvo in aws_acm_certificate.api.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.selected.zone_id
}

resource "aws_acm_certificate_validation" "api" {
  certificate_arn         = aws_acm_certificate.api.arn
  validation_record_fqdns = [for record in aws_route53_record.api_certificate_validation : record.fqdn]
}

resource "aws_lb" "api" {
  name               = "${var.name_prefix}-api"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_security_group_id]
  subnets            = var.public_subnet_ids
  idle_timeout       = var.alb_idle_timeout_seconds

  enable_deletion_protection = false

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-api" })
}

resource "aws_lb_target_group" "api" {
  name        = "${var.name_prefix}-api"
  port        = var.api_container_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  deregistration_delay = 60

  health_check {
    enabled             = true
    path                = var.health_check_path
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-api" })
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.api.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.api.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

resource "aws_lb_listener" "http_redirect" {
  count = var.enable_http_to_https_redirect ? 1 : 0

  load_balancer_arn = aws_lb.api.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_route53_record" "api" {
  zone_id = data.aws_route53_zone.selected.zone_id
  name    = var.api_domain
  type    = "A"

  alias {
    name                   = aws_lb.api.dns_name
    zone_id                = aws_lb.api.zone_id
    evaluate_target_health = true
  }
}

resource "aws_ecs_service" "api" {
  name            = "${var.name_prefix}-api"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  platform_version = "LATEST"

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  health_check_grace_period_seconds  = 60

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.private_app_subnet_ids
    security_groups  = [var.ecs_security_group_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "api"
    container_port   = var.api_container_port
  }

  depends_on = [aws_lb_listener.https]

  lifecycle {
    ignore_changes = [desired_count]
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-api" })
}
