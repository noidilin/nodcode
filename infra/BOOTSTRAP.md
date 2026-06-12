# Infrastructure bootstrap guide

This guide explains how to bootstrap account-level shared infrastructure and then bootstrap each environment (`stage`, future `prod`) without mixing persistent resources with disposable runtime resources.

## Resource boundaries

NodCode infrastructure has three ownership layers:

| Layer | Stack/location | Applies how | Destroy posture |
| --- | --- | --- | --- |
| Shared account bootstrap | `infra/live/shared` | Manual local AWS SSO | Long-lived; do not destroy during env teardown |
| Environment bootstrap | `infra/live/<env>` bootstrap units | Manual local AWS SSO | Long-lived per environment |
| Environment runtime | `infra/live/<env>` runtime units | CI/CD or manual validation | Disposable for stage; protected for prod |

Shared bootstrap currently owns:

- GitHub Actions OIDC provider.
- Shared immutable ECR repository: `devops-nodcode-api`.

Per-environment bootstrap currently owns:

- GitHub OIDC IAM roles for `plan`, `image-push`, and `apply`.
- API runtime Secrets Manager secret shell.
- API CloudWatch log group.

Per-environment runtime currently owns:

- Networking.
- Database.
- API platform: ECS cluster/roles, ALB, ACM/DNS, target group.
- API task definitions.
- API ECS service.

## Prerequisites

Before applying any stack:

1. Authenticate to AWS locally with your SSO profile/session.
2. Confirm the Terraform state bucket exists: `noidilin-tf-state`.
3. Confirm the sandbox permissions boundary exists in the target account: `lab-devops-permissions-boundary`.
4. Confirm Route53 hosted zone and domain inputs are correct for the environment.
5. Confirm Bedrock model access for the configured model/region.
6. Create the matching GitHub Environment, e.g. `stage`, because apply/image-push OIDC roles trust `repo:noidilin/nodcode:environment:<env>`.

## 1. Bootstrap shared account resources

Apply shared once per AWS account:

```sh
cd infra/live/shared
terragrunt stack run init --non-interactive
terragrunt stack run plan --non-interactive
terragrunt stack run apply --non-interactive
```

Expected shared outputs:

- `github-oidc-provider.provider_arn`
- `api-image-repository.repository_name`
- `api-image-repository.repository_url`
- `api-image-repository.repository_arn`

Do not destroy `infra/live/shared` as part of stage/prod runtime teardown.

## 2. Bootstrap stage persistent resources

Stage bootstrap creates deployment identity, the API runtime secret shell, and the API log group. These should survive `destroy-runtime.yml`.

```sh
cd infra/live/stage
terragrunt stack run init --non-interactive \
  --queue-include-dir '.terragrunt-stack/deployment-identity' \
  --queue-include-dir '.terragrunt-stack/api-env-bootstrap'

terragrunt stack run plan --non-interactive --tf-forward-stdout \
  --queue-include-dir '.terragrunt-stack/deployment-identity' \
  --queue-include-dir '.terragrunt-stack/api-env-bootstrap'

terragrunt stack run apply --non-interactive --tf-forward-stdout \
  --queue-include-dir '.terragrunt-stack/deployment-identity' \
  --queue-include-dir '.terragrunt-stack/api-env-bootstrap'
```

Then write real API runtime secrets out-of-band:

```sh
cp infra/secrets/stage.api-runtime.json.example infra/secrets/stage.api-runtime.json
$EDITOR infra/secrets/stage.api-runtime.json

aws secretsmanager put-secret-value \
  --region ap-northeast-1 \
  --secret-id devops-nodcode-stage/api-runtime \
  --secret-string file://infra/secrets/stage.api-runtime.json
```

Never commit `infra/secrets/stage.api-runtime.json`.

## 3. Deploy stage runtime

Preferred path: push/merge to `main` and let `.github/workflows/deploy.yml` build the image, resolve the ECR digest, apply runtime, run migrations, and update the ECS service.

Manual validation path:

```sh
export API_IMAGE_URI='549475122024.dkr.ecr.ap-northeast-1.amazonaws.com/devops-nodcode-api@sha256:...'
cd infra/live/stage
terragrunt stack run plan --non-interactive --tf-forward-stdout \
  --queue-include-dir '.terragrunt-stack/networking' \
  --queue-include-dir '.terragrunt-stack/database' \
  --queue-include-dir '.terragrunt-stack/api-platform' \
  --queue-include-dir '.terragrunt-stack/api-taskdefs' \
  --queue-include-dir '.terragrunt-stack/api-service'

terragrunt stack run apply --non-interactive --tf-forward-stdout \
  --queue-include-dir '.terragrunt-stack/networking' \
  --queue-include-dir '.terragrunt-stack/database' \
  --queue-include-dir '.terragrunt-stack/api-platform' \
  --queue-include-dir '.terragrunt-stack/api-taskdefs' \
  --queue-include-dir '.terragrunt-stack/api-service'
```

Stage intentionally uses disposable database settings:

```hcl
db_deletion_protection = false
db_skip_final_snapshot = true
```

This is for cost-saving runtime teardown only. Do not copy this posture to production.

## 4. Destroy stage runtime only

Preferred path: run `.github/workflows/destroy-runtime.yml` and type `destroy-stage`.

Manual equivalent:

```sh
export API_IMAGE_URI='549475122024.dkr.ecr.ap-northeast-1.amazonaws.com/devops-nodcode-api@sha256:0000000000000000000000000000000000000000000000000000000000000000'
cd infra/live/stage
terragrunt stack run destroy --non-interactive --tf-forward-stdout --queue-include-dir '.terragrunt-stack/api-service'
terragrunt stack run destroy --non-interactive --tf-forward-stdout --queue-include-dir '.terragrunt-stack/api-taskdefs'
terragrunt stack run destroy --non-interactive --tf-forward-stdout --queue-include-dir '.terragrunt-stack/api-platform'
terragrunt stack run destroy --non-interactive --tf-forward-stdout --queue-include-dir '.terragrunt-stack/database'
terragrunt stack run destroy --non-interactive --tf-forward-stdout --queue-include-dir '.terragrunt-stack/networking'
```

Do not include these units in cheap runtime teardown:

- `infra/live/shared/.terragrunt-stack/github-oidc-provider`
- `infra/live/shared/.terragrunt-stack/api-image-repository`
- `infra/live/stage/.terragrunt-stack/deployment-identity`
- `infra/live/stage/.terragrunt-stack/api-env-bootstrap`

## Adding a new environment, e.g. prod

Create `infra/live/prod/terragrunt.stack.hcl` by copying `infra/live/stage/terragrunt.stack.hcl`, then change at least:

- `environment = "prod"`
- `name_prefix = "devops-nodcode-prod"`
- `api_domain`
- VPC CIDR, if stage and prod share one AWS account/region.
- `desired_count`, task sizing, DB sizing, and `db_multi_az`.
- `github_repo` only if the repository changes.
- GitHub Environment name: `prod`.

Production safety differences:

```hcl
db_deletion_protection = true
db_skip_final_snapshot = false
```

Production should normally also use stricter GitHub Environment protection, such as required reviewers, before the apply role can be assumed.

Then bootstrap prod in the same order:

```sh
# Shared stays one-time/account-level; do not recreate if already applied.
cd infra/live/prod
terragrunt stack run apply --non-interactive --tf-forward-stdout \
  --queue-include-dir '.terragrunt-stack/deployment-identity' \
  --queue-include-dir '.terragrunt-stack/api-env-bootstrap'
```

Write prod runtime secrets to the prod secret name, for example:

```sh
aws secretsmanager put-secret-value \
  --region ap-northeast-1 \
  --secret-id devops-nodcode-prod/api-runtime \
  --secret-string file://infra/secrets/prod.api-runtime.json
```

Prod deployment should promote an existing digest-pinned image from shared ECR rather than rebuilding mutable environment tags.
