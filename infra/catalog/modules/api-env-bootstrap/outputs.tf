output "app_runtime_secret_arn" { value = aws_secretsmanager_secret.app.arn }
output "api_log_group_name" { value = aws_cloudwatch_log_group.api.name }
output "api_log_group_arn" { value = aws_cloudwatch_log_group.api.arn }
