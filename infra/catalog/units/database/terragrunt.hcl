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
    private_db_subnet_ids = ["subnet-00000000000000001", "subnet-00000000000000002"]
    db_security_group_id  = "sg-00000000000000001"
  }
}

terraform {
  source = "${find_in_parent_folders("catalog/modules")}//database"
}

inputs = {
  environment             = values.environment
  project                 = values.project
  owner                   = values.owner
  name_prefix             = values.name_prefix
  private_db_subnet_ids   = dependency.networking.outputs.private_db_subnet_ids
  db_security_group_id    = dependency.networking.outputs.db_security_group_id
  db_name                 = values.db_name
  db_username             = values.db_username
  db_instance_class       = values.db_instance_class
  db_allocated_storage_gb = values.db_allocated_storage_gb
  db_engine_version       = values.db_engine_version
  db_multi_az             = values.db_multi_az
  db_deletion_protection  = values.db_deletion_protection
}
