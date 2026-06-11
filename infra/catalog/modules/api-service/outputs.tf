output "ecs_service_name" { value = aws_ecs_service.api.name }
output "ecs_cluster_name" { value = var.ecs_cluster_name }
output "api_url" { value = var.api_url }
