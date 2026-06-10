locals {
  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terragrunt"
    Owner       = var.owner
  }
}

resource "random_password" "db" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret" "db" {
  name                    = "${var.name_prefix}/database"
  description             = "NodCode PostgreSQL credentials"
  recovery_window_in_days = 7

  tags = local.common_tags
}

resource "aws_db_subnet_group" "main" {
  name       = "${var.name_prefix}-db"
  subnet_ids = var.private_db_subnet_ids

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-db" })
}

resource "aws_db_instance" "postgres" {
  identifier = "${var.name_prefix}-postgres"

  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db.result

  allocated_storage     = var.db_allocated_storage_gb
  max_allocated_storage = max(var.db_allocated_storage_gb + 1, 100)
  storage_encrypted     = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [var.db_security_group_id]
  publicly_accessible    = false
  multi_az               = var.db_multi_az

  backup_retention_period   = 7
  deletion_protection       = var.db_deletion_protection
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.name_prefix}-postgres-final"

  auto_minor_version_upgrade = true
  apply_immediately          = false

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-postgres" })
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db.result
    host     = aws_db_instance.postgres.address
    port     = aws_db_instance.postgres.port
    dbname   = var.db_name
  })
}
