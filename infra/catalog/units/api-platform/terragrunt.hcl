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

dependency "database" {
  config_path = "../database"

  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
  mock_outputs = {
    database_secret_arn = "arn:aws:secretsmanager:ap-northeast-1:123456789012:secret:devops-nodcode-staging/database-mock"
  }
}

dependency "api_env_bootstrap" {
  config_path = "../api-env-bootstrap"

  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
  mock_outputs = {
    app_runtime_secret_arn = "arn:aws:secretsmanager:ap-northeast-1:123456789012:secret:devops-nodcode-staging/api-runtime-mock"
    api_log_group_name     = "/ecs/devops-nodcode-staging-api"
  }
}

terraform {
  source = "${find_in_parent_folders("catalog/modules")}//api-platform"
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
  database_secret_arn           = dependency.database.outputs.database_secret_arn
  app_runtime_secret_arn        = dependency.api_env_bootstrap.outputs.app_runtime_secret_arn
  api_log_group_name            = dependency.api_env_bootstrap.outputs.api_log_group_name
  hosted_zone_name              = values.hosted_zone_name
  api_domain                    = values.api_domain
  enable_http_to_https_redirect = values.enable_http_to_https_redirect
  alb_idle_timeout_seconds      = values.alb_idle_timeout_seconds
  api_container_port            = values.api_container_port
  health_check_path             = values.health_check_path
  bedrock_region                = values.bedrock_region
  bedrock_chat_model_id         = values.bedrock_chat_model_id
  additional_bedrock_model_arns = values.additional_bedrock_model_arns
}
