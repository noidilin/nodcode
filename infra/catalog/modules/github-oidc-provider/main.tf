resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = [
    "sts.amazonaws.com",
  ]

  # AWS IAM now ignores thumbprints for GitHub's trusted OIDC provider, but the
  # provider schema still requires this attribute.
  thumbprint_list = []

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terragrunt"
    Owner       = var.owner
    Name        = "github-actions-oidc"
  }
}
