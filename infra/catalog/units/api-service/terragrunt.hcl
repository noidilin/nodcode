include "root" {
  path = find_in_parent_folders("root.hcl")
}

remote_state {
  backend = "s3"

  generate = {
    path      = "backend.tf"
    if_exists = "overwrite"
  }

  config = {
    bucket       = "noidilin-tf-state"
    key          = "nodcode/live/${values.environment}/${basename(get_terragrunt_dir())}/terraform.tfstate"
    region       = values.aws_region
    encrypt      = true
    use_lockfile = true
  }
}

dependency "networking" {
  config_path = "../networking"

  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
  mock_outputs = {
    vpc_id                 = "vpc-00000000000000000"
    public_subnet_ids      = ["subnet-00000000000000001", "subnet-00000000000000002"]
    private_app_subnet_ids = ["subnet-00000000000000003", "subnet-00000000000000004"]
    alb_security_group_id  = "sg-00000000000000001"
    ecs_security_group_id  = "sg-00000000000000002"
  }
}

dependency "api_bootstrap" {
  config_path = "../api-bootstrap"

  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
  mock_outputs = {
    ecr_repository_url = "123456789012.dkr.ecr.ap-northeast-1.amazonaws.com/nodcode-staging-api"
  }
}

dependency "database" {
  config_path = "../database"

  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
  mock_outputs = {
    database_url = "postgresql://nodcode:mock@localhost:5432/nodcode?schema=public"
  }
}

terraform {
  source = "${find_in_parent_folders("catalog/modules")}//api-service"
}

inputs = {
  aws_region                    = values.aws_region
  environment                   = values.environment
  project                       = values.project
  owner                         = values.owner
  name_prefix                   = values.name_prefix
  vpc_id                        = dependency.networking.outputs.vpc_id
  public_subnet_ids             = dependency.networking.outputs.public_subnet_ids
  private_app_subnet_ids        = dependency.networking.outputs.private_app_subnet_ids
  alb_security_group_id         = dependency.networking.outputs.alb_security_group_id
  ecs_security_group_id         = dependency.networking.outputs.ecs_security_group_id
  ecr_repository_url            = dependency.api_bootstrap.outputs.ecr_repository_url
  database_url                  = dependency.database.outputs.database_url
  hosted_zone_name              = values.hosted_zone_name
  api_domain                    = values.api_domain
  enable_http_to_https_redirect = values.enable_http_to_https_redirect
  alb_idle_timeout_seconds      = values.alb_idle_timeout_seconds
  api_container_port            = values.api_container_port
  health_check_path             = values.health_check_path
  image_tag                     = values.image_tag
  task_cpu                      = values.task_cpu
  task_memory                   = values.task_memory
  desired_count                 = values.desired_count
  log_retention_days            = values.log_retention_days
  polar_server                  = values.polar_server
  bedrock_region                = values.bedrock_region
  bedrock_chat_model_id         = values.bedrock_chat_model_id
  additional_bedrock_model_arns = values.additional_bedrock_model_arns
}
