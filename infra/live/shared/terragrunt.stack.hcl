locals {
  environment         = "shared"
  project             = "nodcode"
  owner               = "noidilin"
  aws_region          = "ap-northeast-1"
  api_repository_name = "devops-nodcode-api"
  max_image_count     = 50
  units_path          = find_in_parent_folders("catalog/units")
}

unit "github-oidc-provider" {
  source = "${local.units_path}/github-oidc-provider"
  path   = "github-oidc-provider"

  values = {
    environment = local.environment
    project     = local.project
    owner       = local.owner
    aws_region  = local.aws_region
  }
}

unit "api-image-repository" {
  source = "${local.units_path}/api-image-repository"
  path   = "api-image-repository"

  values = {
    environment         = local.environment
    project             = local.project
    owner               = local.owner
    aws_region          = local.aws_region
    api_repository_name = local.api_repository_name
    max_image_count     = local.max_image_count
  }
}
