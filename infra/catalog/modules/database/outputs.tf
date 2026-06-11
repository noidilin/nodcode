output "database_secret_arn" { value = aws_secretsmanager_secret.db.arn }
output "database_endpoint" { value = aws_db_instance.postgres.address }
