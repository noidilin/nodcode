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

dependency "github_oidc_provider" {
  config_path = "../../../shared/.terragrunt-stack/github-oidc-provider"

  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
  mock_outputs = {
    provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  }
}

dependency "api_image_repository" {
  config_path = "../../../shared/.terragrunt-stack/api-image-repository"

  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
  mock_outputs = {
    repository_arn = "arn:aws:ecr:ap-northeast-1:123456789012:repository/devops-nodcode-api"
  }
}

terraform {
  source = "${find_in_parent_folders("catalog/modules")}//deployment-identity"
}

inputs = {
  environment                = values.environment
  project                    = values.project
  owner                      = values.owner
  name_prefix                = values.name_prefix
  github_repo                = values.github_repo
  github_oidc_provider_arn   = dependency.github_oidc_provider.outputs.provider_arn
  ecr_repository_arn         = dependency.api_image_repository.outputs.repository_arn
  terraform_state_bucket_arn = values.terraform_state_bucket_arn
}
