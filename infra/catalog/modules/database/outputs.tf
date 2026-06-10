output "database_secret_arn" { value = aws_secretsmanager_secret.db.arn }
output "database_endpoint" { value = aws_db_instance.postgres.address }
output "database_url" {
  value     = "postgresql://${var.db_username}:${urlencode(random_password.db.result)}@${aws_db_instance.postgres.address}:${aws_db_instance.postgres.port}/${var.db_name}?schema=public"
  sensitive = true
}
