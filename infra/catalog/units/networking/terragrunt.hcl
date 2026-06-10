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

terraform {
  source = "${find_in_parent_folders("catalog/modules")}//networking"
}

inputs = {
  environment                   = values.environment
  project                       = values.project
  owner                         = values.owner
  name_prefix                   = values.name_prefix
  vpc_cidr                      = values.vpc_cidr
  az_count                      = values.az_count
  allowed_http_cidr_blocks      = values.allowed_http_cidr_blocks
  enable_http_to_https_redirect = values.enable_http_to_https_redirect
  enable_nat_gateway            = values.enable_nat_gateway
  api_container_port            = values.api_container_port
}
