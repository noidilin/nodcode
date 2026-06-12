locals {
  environment                = "stage"
  project                    = "nodcode"
  owner                      = "noidilin"
  aws_region                 = "ap-northeast-1"
  account_id                 = "549475122024"
  github_repo                = "noidilin/nodcode"
  terraform_state_bucket_arn = "arn:aws:s3:::noidilin-tf-state"
  name_prefix                = "devops-${local.project}-${local.environment}"
  units_path                 = find_in_parent_folders("catalog/units")

  # Stage control-plane network.
  vpc_cidr = "10.42.0.0/16"
  az_count = 2

  hosted_zone_name = "noidilin.dev"
  api_domain       = "stage.nodcode.noidilin.dev"

  allowed_http_cidr_blocks      = ["0.0.0.0/0"]
  enable_http_to_https_redirect = true
  enable_nat_gateway            = true
  alb_idle_timeout_seconds      = 300

  api_container_port = 3000
  health_check_path  = "/health"
  api_image_uri      = get_env("API_IMAGE_URI", "${local.account_id}.dkr.ecr.${local.aws_region}.amazonaws.com/devops-nodcode-api@sha256:0000000000000000000000000000000000000000000000000000000000000000")
  task_cpu           = 512
  task_memory        = 1024
  desired_count      = 1
  log_retention_days = 30

  db_name                 = "nodcode"
  db_username             = "nodcode"
  db_instance_class       = "db.t4g.micro"
  db_allocated_storage_gb = 20
  db_engine_version       = "16"
  db_multi_az             = false
  # Stage is disposable to support cheap runtime teardown.
  # Production must enable deletion protection and final snapshot/backup retention.
  db_deletion_protection = false
  db_skip_final_snapshot = true

  bedrock_region                = "ap-northeast-1"
  bedrock_chat_model_id         = "deepseek.v3.2"
  additional_bedrock_model_arns = []
}

unit "deployment-identity" {
  source = "${local.units_path}/deployment-identity"
  path   = "deployment-identity"

  values = {
    environment                = local.environment
    project                    = local.project
    owner                      = local.owner
    aws_region                 = local.aws_region
    name_prefix                = local.name_prefix
    github_repo                = local.github_repo
    terraform_state_bucket_arn = local.terraform_state_bucket_arn
  }
}

unit "api-env-bootstrap" {
  source = "${local.units_path}/api-env-bootstrap"
  path   = "api-env-bootstrap"

  values = {
    environment        = local.environment
    project            = local.project
    owner              = local.owner
    aws_region         = local.aws_region
    name_prefix        = local.name_prefix
    log_retention_days = local.log_retention_days
  }
}

unit "networking" {
  source = "${local.units_path}/networking"
  path   = "networking"

  values = {
    environment                   = local.environment
    project                       = local.project
    owner                         = local.owner
    aws_region                    = local.aws_region
    name_prefix                   = local.name_prefix
    vpc_cidr                      = local.vpc_cidr
    az_count                      = local.az_count
    allowed_http_cidr_blocks      = local.allowed_http_cidr_blocks
    enable_http_to_https_redirect = local.enable_http_to_https_redirect
    enable_nat_gateway            = local.enable_nat_gateway
    api_container_port            = local.api_container_port
  }
}

unit "database" {
  source = "${local.units_path}/database"
  path   = "database"

  values = {
    environment             = local.environment
    project                 = local.project
    owner                   = local.owner
    aws_region              = local.aws_region
    name_prefix             = local.name_prefix
    db_name                 = local.db_name
    db_username             = local.db_username
    db_instance_class       = local.db_instance_class
    db_allocated_storage_gb = local.db_allocated_storage_gb
    db_engine_version       = local.db_engine_version
    db_multi_az             = local.db_multi_az
    db_deletion_protection  = local.db_deletion_protection
    db_skip_final_snapshot  = local.db_skip_final_snapshot
  }
}

unit "api-platform" {
  source = "${local.units_path}/api-platform"
  path   = "api-platform"

  values = {
    environment                   = local.environment
    project                       = local.project
    owner                         = local.owner
    aws_region                    = local.aws_region
    name_prefix                   = local.name_prefix
    hosted_zone_name              = local.hosted_zone_name
    api_domain                    = local.api_domain
    enable_http_to_https_redirect = local.enable_http_to_https_redirect
    alb_idle_timeout_seconds      = local.alb_idle_timeout_seconds
    api_container_port            = local.api_container_port
    health_check_path             = local.health_check_path
    bedrock_region                = local.bedrock_region
    bedrock_chat_model_id         = local.bedrock_chat_model_id
    additional_bedrock_model_arns = local.additional_bedrock_model_arns
  }
}

unit "api-taskdefs" {
  source = "${local.units_path}/api-taskdefs"
  path   = "api-taskdefs"

  values = {
    environment           = local.environment
    project               = local.project
    owner                 = local.owner
    aws_region            = local.aws_region
    name_prefix           = local.name_prefix
    api_image_uri         = local.api_image_uri
    task_cpu              = local.task_cpu
    task_memory           = local.task_memory
    bedrock_region        = local.bedrock_region
    bedrock_chat_model_id = local.bedrock_chat_model_id
  }
}

unit "api-service" {
  source = "${local.units_path}/api-service"
  path   = "api-service"

  values = {
    environment   = local.environment
    project       = local.project
    owner         = local.owner
    aws_region    = local.aws_region
    name_prefix   = local.name_prefix
    desired_count = local.desired_count
  }
}
