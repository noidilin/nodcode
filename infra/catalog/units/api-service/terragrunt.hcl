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

  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs = {
    ecs_cluster_name       = "devops-nodcode-staging-cluster"
    ecs_cluster_arn        = "arn:aws:ecs:ap-northeast-1:123456789012:cluster/devops-nodcode-staging-cluster"
    target_group_arn       = "arn:aws:elasticloadbalancing:ap-northeast-1:123456789012:targetgroup/devops-nodcode-staging-api/0000000000000000"
    private_app_subnet_ids = ["subnet-00000000000000003", "subnet-00000000000000004"]
    ecs_security_group_id  = "sg-00000000000000002"
    api_container_port     = 3000
    api_url                = "https://staging.nodcode.noidilin.dev"
  }
}

dependency "api_taskdefs" {
  config_path = "../api-taskdefs"

  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs = {
    api_task_definition_arn = "arn:aws:ecs:ap-northeast-1:123456789012:task-definition/devops-nodcode-staging-api:1"
    container_name          = "api"
  }
}

terraform {
  source = "${find_in_parent_folders("catalog/modules")}//api-service"
}

inputs = {
  environment             = values.environment
  project                 = values.project
  owner                   = values.owner
  name_prefix             = values.name_prefix
  ecs_cluster_name        = dependency.api_platform.outputs.ecs_cluster_name
  ecs_cluster_arn         = dependency.api_platform.outputs.ecs_cluster_arn
  api_task_definition_arn = dependency.api_taskdefs.outputs.api_task_definition_arn
  target_group_arn        = dependency.api_platform.outputs.target_group_arn
  private_app_subnet_ids  = dependency.api_platform.outputs.private_app_subnet_ids
  ecs_security_group_id   = dependency.api_platform.outputs.ecs_security_group_id
  container_name          = dependency.api_taskdefs.outputs.container_name
  api_container_port      = dependency.api_platform.outputs.api_container_port
  desired_count           = values.desired_count
  api_url                 = dependency.api_platform.outputs.api_url
}
