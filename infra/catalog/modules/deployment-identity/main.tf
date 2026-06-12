data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "github_plan_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:pull_request"]
    }
  }
}

data "aws_iam_policy_document" "github_environment_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:environment:${var.environment}"]
    }
  }
}

locals {
  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terragrunt"
    Owner       = var.owner
  }

  runtime_boundary_arn      = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/lab-devops-permissions-boundary"
  gitops_apply_boundary_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/lab-gitops-oidc-apply-permissions-boundary"
  name_prefix               = "${var.name_prefix}-github"
}

resource "aws_iam_role" "plan" {
  name                 = "${local.name_prefix}-plan"
  assume_role_policy   = data.aws_iam_policy_document.github_plan_trust.json
  max_session_duration = 3600
  permissions_boundary = local.gitops_apply_boundary_arn
  tags                 = local.common_tags
}

resource "aws_iam_role" "image_push" {
  name                 = "${local.name_prefix}-image-push"
  assume_role_policy   = data.aws_iam_policy_document.github_environment_trust.json
  max_session_duration = 3600
  permissions_boundary = local.runtime_boundary_arn
  tags                 = local.common_tags
}

resource "aws_iam_role" "apply" {
  name                 = "${local.name_prefix}-apply"
  assume_role_policy   = data.aws_iam_policy_document.github_environment_trust.json
  max_session_duration = 3600
  permissions_boundary = local.gitops_apply_boundary_arn
  tags                 = local.common_tags
}

data "aws_iam_policy_document" "plan" {
  statement {
    sid       = "ReadTerraformStateAndLocks"
    actions   = ["s3:GetObject", "s3:ListBucket", "s3:GetBucketLocation"]
    resources = [var.terraform_state_bucket_arn, "${var.terraform_state_bucket_arn}/*"]
  }

  statement {
    sid       = "DescribeEnvironmentResources"
    actions   = ["acm:Describe*", "acm:List*", "application-autoscaling:Describe*", "cloudwatch:Describe*", "ec2:Describe*", "ecr:Describe*", "ecs:Describe*", "ecs:List*", "elasticloadbalancing:Describe*", "iam:Get*", "iam:List*", "logs:Describe*", "rds:Describe*", "route53:Get*", "route53:List*", "secretsmanager:DescribeSecret", "secretsmanager:ListSecrets", "sts:GetCallerIdentity"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "plan" {
  name   = "${var.environment}-plan"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.plan.json
}

data "aws_iam_policy_document" "image_push" {
  statement {
    sid       = "GetEcrAuthorization"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "PushApiImages"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:DescribeImageScanFindings",
      "ecr:DescribeRepositories",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart"
    ]
    resources = [var.ecr_repository_arn]
  }
}

resource "aws_iam_role_policy" "image_push" {
  name   = "api-image-push"
  role   = aws_iam_role.image_push.id
  policy = data.aws_iam_policy_document.image_push.json
}

data "aws_iam_policy_document" "apply" {
  statement {
    sid       = "ManageTerraformStateAndLocks"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket", "s3:GetBucketLocation"]
    resources = [var.terraform_state_bucket_arn, "${var.terraform_state_bucket_arn}/*"]
  }

  statement {
    sid       = "ManageEnvironmentRuntime"
    actions   = ["acm:*", "application-autoscaling:*", "cloudwatch:*", "ec2:*", "ecs:*", "elasticloadbalancing:*", "logs:*", "rds:*", "route53:*", "secretsmanager:*", "sts:GetCallerIdentity"]
    resources = ["*"]
  }

  statement {
    sid = "ManageTaskRolesForRuntime"
    actions = [
      "iam:AttachRolePolicy",
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy",
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:ListRolePolicies",
      "iam:ListRoleTags",
      "iam:PassRole",
      "iam:PutRolePermissionsBoundary",
      "iam:PutRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:UpdateRole"
    ]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.name_prefix}-ecs-*"]

    condition {
      test     = "StringEqualsIfExists"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "apply" {
  name   = "${var.environment}-apply"
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.apply.json
}
