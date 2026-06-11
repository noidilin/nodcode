output "api_task_definition_arn" { value = aws_ecs_task_definition.api.arn }
output "migration_task_definition_arn" { value = aws_ecs_task_definition.database_migration.arn }
output "container_name" { value = local.container_name }
output "api_image_uri" { value = var.api_image_uri }
