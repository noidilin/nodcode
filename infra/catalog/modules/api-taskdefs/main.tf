locals {
  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terragrunt"
    Owner       = var.owner
  }

  container_name = "api"
}

resource "aws_ecs_task_definition" "api" {
  family                   = "${var.name_prefix}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.task_cpu)
  memory                   = tostring(var.task_memory)
  execution_role_arn       = var.ecs_execution_role_arn
  task_role_arn            = var.ecs_task_role_arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = local.container_name
      image     = var.api_image_uri
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
        { name = "NODE_EXTRA_CA_CERTS", value = "/usr/local/share/ca-certificates/rds-global-bundle.crt" },
        { name = "BEDROCK_AWS_REGION", value = var.bedrock_region },
        { name = "BEDROCK_CHAT_MODEL_ID", value = var.bedrock_chat_model_id }
      ]

      secrets = [
        { name = "DATABASE_URL", valueFrom = "${var.database_secret_arn}:DATABASE_URL::" },
        { name = "CLERK_SECRET_KEY", valueFrom = "${var.app_runtime_secret_arn}:CLERK_SECRET_KEY::" },
        { name = "CLERK_PUBLISHABLE_KEY", valueFrom = "${var.app_runtime_secret_arn}:CLERK_PUBLISHABLE_KEY::" },
        { name = "POLAR_ACCESS_TOKEN", valueFrom = "${var.app_runtime_secret_arn}:POLAR_ACCESS_TOKEN::" },
        { name = "POLAR_PRODUCT_ID", valueFrom = "${var.app_runtime_secret_arn}:POLAR_PRODUCT_ID::" },
        { name = "POLAR_CREDITS_METER_ID", valueFrom = "${var.app_runtime_secret_arn}:POLAR_CREDITS_METER_ID::" },
        { name = "POLAR_SERVER", valueFrom = "${var.app_runtime_secret_arn}:POLAR_SERVER::" },
        { name = "SENTRY_DSN", valueFrom = "${var.app_runtime_secret_arn}:SENTRY_DSN::" },
        { name = "ANTHROPIC_API_KEY", valueFrom = "${var.app_runtime_secret_arn}:ANTHROPIC_API_KEY::" },
        { name = "OPENAI_API_KEY", valueFrom = "${var.app_runtime_secret_arn}:OPENAI_API_KEY::" },
        { name = "AWS_BEARER_TOKEN_BEDROCK", valueFrom = "${var.app_runtime_secret_arn}:AWS_BEARER_TOKEN_BEDROCK::" }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = var.api_log_group_name
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

  tags = local.common_tags
}

resource "aws_ecs_task_definition" "database_migration" {
  family                   = "${var.name_prefix}-database-migration"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.task_cpu)
  memory                   = tostring(var.task_memory)
  execution_role_arn       = var.ecs_execution_role_arn
  task_role_arn            = var.ecs_task_role_arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name      = "migration"
      image     = var.api_image_uri
      essential = true
      command   = ["bun", "run", "--cwd", "packages/database", "db:migrate:deploy"]

      environment = [
        { name = "NODE_ENV", value = "production" },
        { name = "NODE_EXTRA_CA_CERTS", value = "/usr/local/share/ca-certificates/rds-global-bundle.crt" }
      ]

      secrets = [
        { name = "DATABASE_URL", valueFrom = "${var.database_secret_arn}:DATABASE_URL::" }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = var.api_log_group_name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "migration"
          mode                  = "blocking"
        }
      }
    }
  ])

  tags = local.common_tags
}
