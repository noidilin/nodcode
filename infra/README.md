# NodCode infrastructure

Terraform + Terragrunt infrastructure for the AWS migration.

## Layout

```text
infra/
  catalog/
    modules/                   # Reusable Terraform feature modules
      networking/              # VPC, public/app/db subnets, routing, and security groups
      api-bootstrap/           # ECR repository and lifecycle policy for API images
      database/                # RDS PostgreSQL and generated database secret
      api-service/             # ECS Fargate API, ALB, ACM/DNS, logs, runtime secret, Bedrock IAM
    units/                     # Terragrunt unit wiring, one state per feature
  live/
    root.hcl                     # Shared AWS provider generation
    shared/terragrunt.stack.hcl  # Account-level bootstrap resources
    staging/terragrunt.stack.hcl # Staging stack inputs
```

The stack follows the feature-module pattern from `/Users/noid/hub/dev/web-lf2/infra`: small reusable modules in `catalog/modules`, Terragrunt wrappers in `catalog/units`, and environment composition in `live/*/terragrunt.stack.hcl`. IAM role names use the AWS sandbox-approved `devops-*` prefix, and runtime roles use the pre-existing `lab-devops-permissions-boundary`.

Docs:

- Bootstrap guide: `BOOTSTRAP.md`
- Phase 1 runbook: `../docs/runbooks/phase-1-infra.md`

## Local commands

```sh
# Format Terragrunt HCL
terragrunt hcl format --check --diff --working-dir infra

# Format Terraform modules
find infra/catalog/modules -name "*.tf" -exec terraform fmt -check -diff {} \;

# Validate staging
cd infra/live/staging && terragrunt stack run validate

# Plan staging with a placeholder image digest
cd infra/live/staging
API_IMAGE_URI='000000000000.dkr.ecr.ap-northeast-1.amazonaws.com/devops-nodcode-api@sha256:0000000000000000000000000000000000000000000000000000000000000000' \
  terragrunt stack run plan
```

State is stored in S3 using the same unit-per-feature-state pattern as `/Users/noid/hub/dev/web-lf2/infra`.
Owner-specific values live in `infra/live/staging/terragrunt.stack.hcl`; review the Route53 zone and API domain before applying.
