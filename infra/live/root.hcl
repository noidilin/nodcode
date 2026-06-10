generate "providers" {
  path      = "providers.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
provider "aws" {
  region = "ap-northeast-1"

  default_tags {
    tags = {
      Project   = "nodcode"
      ManagedBy = "terragrunt"
      Owner     = "noidilin"
    }
  }
}
EOF
}
