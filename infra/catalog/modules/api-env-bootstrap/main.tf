locals {
  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terragrunt"
    Owner       = var.owner
  }
}

resource "aws_secretsmanager_secret" "app" {
  name                    = "${var.name_prefix}/api-runtime"
  description             = "NodCode API runtime third-party secrets. Values are written out-of-band and must not be passed through Terraform."
  recovery_window_in_days = 7

  tags = local.common_tags
}

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
