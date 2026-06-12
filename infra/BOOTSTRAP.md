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

Preferred script:

```sh
AWS_REGION=ap-northeast-1 infra/scripts/bootstrap-shared.sh
```

Manual equivalent. Apply shared once per AWS account. Prefer stack filters so shared bootstrap stays explicit:

```sh
cd infra/live/shared
terragrunt stack run apply --non-interactive --tf-forward-stdout \
  --filter github-oidc-provider \
  --filter api-image-repository
```

Expected shared outputs:

- `github-oidc-provider.provider_arn`
- `api-image-repository.repository_name`
- `api-image-repository.repository_url`
- `api-image-repository.repository_arn`

If these resources existed before a rename/state-path change, the first apply may fail with `EntityAlreadyExists` / repository already exists. Import the existing resources into the generated stack unit state, then re-run the filtered apply:

```sh
cd infra/live/shared
terragrunt stack generate

OIDC_ARN=$(aws iam list-open-id-connect-providers \
  --query "OpenIDConnectProviderList[?contains(Arn, 'token.actions.githubusercontent.com')].Arn | [0]" \
  --output text)

cd .terragrunt-stack/github-oidc-provider
terragrunt import aws_iam_openid_connect_provider.github "$OIDC_ARN"

cd ../api-image-repository
terragrunt import aws_ecr_repository.api devops-nodcode-api
terragrunt import aws_ecr_lifecycle_policy.api devops-nodcode-api || true
```

Do not destroy `infra/live/shared` as part of stage/prod runtime teardown.

## 2. Bootstrap stage persistent resources

Stage bootstrap creates deployment identity, the API runtime secret shell, and the API log group. These should survive `destroy-runtime.yml`.

Preferred script:

```sh
AWS_REGION=ap-northeast-1 ENVIRONMENT=stage infra/scripts/bootstrap-stage-persistent.sh
```

Manual equivalent:

```sh
cd infra/live/stage
terragrunt stack run apply --non-interactive --tf-forward-stdout \
  --filter deployment-identity \
  --filter api-env-bootstrap
```

If this is a re-bootstrap after renaming resources/workflow variables, the IAM roles may already exist while the new state path is empty. Import the roles into the `deployment-identity` unit, then re-run the filtered apply. Missing inline-policy imports are fine; `apply` will create them.

```sh
cd infra/live/stage
terragrunt stack generate
cd .terragrunt-stack/deployment-identity

terragrunt import aws_iam_role.plan devops-nodcode-stage-github-plan
terragrunt import aws_iam_role.image_push devops-nodcode-stage-github-image-push
terragrunt import aws_iam_role.apply devops-nodcode-stage-github-apply

# Optional: only if these inline policies already exist.
terragrunt import aws_iam_role_policy.plan devops-nodcode-stage-github-plan:stage-plan || true
terragrunt import aws_iam_role_policy.image_push devops-nodcode-stage-github-image-push:api-image-push || true
terragrunt import aws_iam_role_policy.apply devops-nodcode-stage-github-apply:stage-apply || true

cd ../..
terragrunt stack run apply --non-interactive --tf-forward-stdout \
  --filter deployment-identity \
  --filter api-env-bootstrap
```

Then write real API runtime secrets out-of-band from the repository root:

```sh
cp infra/secrets/stage.api-runtime.json.example infra/secrets/stage.api-runtime.json
$EDITOR infra/secrets/stage.api-runtime.json

aws secretsmanager put-secret-value \
  --region ap-northeast-1 \
  --secret-id devops-nodcode-stage/api-runtime \
  --secret-string file://infra/secrets/stage.api-runtime.json
```

Never commit `infra/secrets/stage.api-runtime.json`.

## 3. Build and push the API image manually

CI/CD builds `tui/Dockerfile`, pushes the shared ECR tag `sha-${GITHUB_SHA}`, resolves the immutable digest, and deploys with `API_IMAGE_URI=...@sha256:...`. If pushing manually, use the same tag convention and build for `linux/amd64` because the ECS task definition currently declares `X86_64`. This matters on Apple Silicon Macs.

```sh
AWS_REGION=ap-northeast-1
REPO=devops-nodcode-api
ECR_REPOSITORY_URL=$(cd infra/live/shared/.terragrunt-stack/api-image-repository && terragrunt output -raw repository_url)
REGISTRY=${ECR_REPOSITORY_URL%/*}
IMAGE_TAG="sha-$(git rev-parse HEAD)"

aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"

# The ECR repo is immutable. Delete the old tag first if intentionally rebuilding
# the same commit image, or skip the build when the tag already exists.
docker buildx build \
  --platform linux/amd64 \
  -f tui/Dockerfile \
  -t "$ECR_REPOSITORY_URL:$IMAGE_TAG" \
  --push \
  tui

DIGEST=$(aws ecr describe-images \
  --region "$AWS_REGION" \
  --repository-name "$REPO" \
  --image-ids imageTag="$IMAGE_TAG" \
  --query 'imageDetails[0].imageDigest' \
  --output text)

export API_IMAGE_URI="$ECR_REPOSITORY_URL@$DIGEST"
echo "$API_IMAGE_URI"
```

Audit images after push:

```sh
aws ecr describe-images \
  --region ap-northeast-1 \
  --repository-name devops-nodcode-api \
  --query 'sort_by(imageDetails,& imagePushedAt)[].{pushedAt:imagePushedAt,tags:imageTags,digest:imageDigest,sizeBytes:imageSizeInBytes}' \
  --output table
```

`docker buildx --push` may create untagged platform/provenance records alongside the tagged manifest list. Deploy the tagged manifest-list digest returned by the `imageTag` lookup above.

## 4. Deploy stage runtime

Preferred path: push/merge to `main` and let `.github/workflows/deploy.yml` build the image, resolve the ECR digest, apply runtime, run migrations, and update the ECS service.

Manual validation path:

```sh
export API_IMAGE_URI='549475122024.dkr.ecr.ap-northeast-1.amazonaws.com/devops-nodcode-api@sha256:...'
cd infra/live/stage
terragrunt stack run plan --non-interactive --tf-forward-stdout \
  --filter networking \
  --filter database \
  --filter api-platform \
  --filter api-taskdefs \
  --filter api-service

terragrunt stack run apply --non-interactive --tf-forward-stdout \
  --filter networking \
  --filter database \
  --filter api-platform \
  --filter api-taskdefs \
  --filter api-service
```

Stage intentionally uses disposable database settings:

```hcl
db_deletion_protection = false
db_skip_final_snapshot = true
```

This is for cost-saving runtime teardown only. Do not copy this posture to production.

## 5. Destroy stage runtime only

Preferred path: run `.github/workflows/destroy-runtime.yml` and type `destroy-stage`.

Manual equivalent:

```sh
export API_IMAGE_URI='549475122024.dkr.ecr.ap-northeast-1.amazonaws.com/devops-nodcode-api@sha256:0000000000000000000000000000000000000000000000000000000000000000'
cd infra/live/stage
terragrunt stack run destroy --non-interactive --tf-forward-stdout --filter api-service
terragrunt stack run destroy --non-interactive --tf-forward-stdout --filter api-taskdefs
terragrunt stack run destroy --non-interactive --tf-forward-stdout --filter api-platform
terragrunt stack run destroy --non-interactive --tf-forward-stdout --filter database
terragrunt stack run destroy --non-interactive --tf-forward-stdout --filter networking
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
  --filter deployment-identity \
  --filter api-env-bootstrap
```

Write prod runtime secrets to the prod secret name, for example:

```sh
aws secretsmanager put-secret-value \
  --region ap-northeast-1 \
  --secret-id devops-nodcode-prod/api-runtime \
  --secret-string file://infra/secrets/prod.api-runtime.json
```

Prod deployment should promote an existing digest-pinned image from shared ECR rather than rebuilding mutable environment tags.
