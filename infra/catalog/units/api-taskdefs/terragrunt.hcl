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

dependency "api_platform" {
  config_path = "../api-platform"

  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
  mock_outputs = {
    ecs_execution_role_arn = "arn:aws:iam::123456789012:role/devops-nodcode-staging-ecs-execution"
    ecs_task_role_arn      = "arn:aws:iam::123456789012:role/devops-nodcode-staging-ecs-task"
    api_container_port     = 3000
    health_check_path      = "/health"
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
  source = "${find_in_parent_folders("catalog/modules")}//api-taskdefs"
}

inputs = {
  aws_region             = values.aws_region
  environment            = values.environment
  project                = values.project
  owner                  = values.owner
  name_prefix            = values.name_prefix
  api_image_uri          = values.api_image_uri
  ecs_execution_role_arn = dependency.api_platform.outputs.ecs_execution_role_arn
  ecs_task_role_arn      = dependency.api_platform.outputs.ecs_task_role_arn
  database_secret_arn    = dependency.database.outputs.database_secret_arn
  app_runtime_secret_arn = dependency.api_env_bootstrap.outputs.app_runtime_secret_arn
  api_log_group_name     = dependency.api_env_bootstrap.outputs.api_log_group_name
  api_container_port     = dependency.api_platform.outputs.api_container_port
  health_check_path      = dependency.api_platform.outputs.health_check_path
  task_cpu               = values.task_cpu
  task_memory            = values.task_memory
  bedrock_region         = values.bedrock_region
  bedrock_chat_model_id  = values.bedrock_chat_model_id
}
