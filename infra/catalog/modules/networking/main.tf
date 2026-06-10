data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)
  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terragrunt"
    Owner       = var.owner
  }
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-network" })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-igw" })
}

resource "aws_subnet" "public" {
  count = var.az_count

  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-public-${count.index + 1}", Tier = "public" })
}

resource "aws_subnet" "private_app" {
  count = var.az_count

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10)
  availability_zone = local.azs[count.index]

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-private-app-${count.index + 1}", Tier = "private-app" })
}

resource "aws_subnet" "private_db" {
  count = var.az_count

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 20)
  availability_zone = local.azs[count.index]

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-private-db-${count.index + 1}", Tier = "private-db" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-public" })
}

resource "aws_route_table_association" "public" {
  count = var.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  count = var.enable_nat_gateway ? 1 : 0

  domain = "vpc"

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-nat" })
}

resource "aws_nat_gateway" "main" {
  count = var.enable_nat_gateway ? 1 : 0

  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-nat" })

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "private_app" {
  vpc_id = aws_vpc.main.id

  dynamic "route" {
    for_each = var.enable_nat_gateway ? [1] : []
    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = aws_nat_gateway.main[0].id
    }
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-private-app" })
}

resource "aws_route_table_association" "private_app" {
  count = var.az_count

  subnet_id      = aws_subnet.private_app[count.index].id
  route_table_id = aws_route_table.private_app.id
}

resource "aws_route_table" "private_db" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-private-db" })
}

resource "aws_route_table_association" "private_db" {
  count = var.az_count

  subnet_id      = aws_subnet.private_db[count.index].id
  route_table_id = aws_route_table.private_db.id
}

resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-alb"
  description = "Public ALB ingress for NodCode API"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTPS from approved clients"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.allowed_http_cidr_blocks
  }

  dynamic "ingress" {
    for_each = var.enable_http_to_https_redirect ? [1] : []
    content {
      description = "HTTP redirect to HTTPS"
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      cidr_blocks = var.allowed_http_cidr_blocks
    }
  }

  egress {
    description = "Forward to ECS tasks"
    from_port   = var.api_container_port
    to_port     = var.api_container_port
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-alb" })
}

resource "aws_security_group" "ecs_tasks" {
  name        = "${var.name_prefix}-ecs-tasks"
  description = "NodCode API tasks: inbound only from ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "API traffic from ALB"
    from_port       = var.api_container_port
    to_port         = var.api_container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "Outbound to database, AWS APIs, and SaaS integrations"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-ecs-tasks" })
}

resource "aws_security_group" "db" {
  name        = "${var.name_prefix}-db"
  description = "PostgreSQL reachable only from ECS tasks"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "PostgreSQL from NodCode API tasks"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_tasks.id]
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-db" })
}
