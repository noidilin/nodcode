# NodCode CI/CD Workflow Implementation Plan

## Purpose

Build a staging-first GitHub Actions delivery system for NodCode that borrows the strongest patterns from the referenced `devops` and `web-lf2` repositories while fitting NodCode's current AWS/Terragrunt shape.

The first milestone is **automatic main-branch deployment to staging**, with production-shaped conventions but no production workflow yet.

Primary goals:

- PRs prove application, container, and staging infrastructure changes before merge.
- Main branch deploys to staging through AWS OIDC, with no long-lived AWS keys.
- The API image is built once, pushed once, and deployed by digest.
- Database migrations run before the ECS service is updated to the new task definition.
- Expensive staging runtime can be destroyed while cheap bootstrap resources survive.
- Future production promotion can reuse the same artifact model without redesign.

## Reference Patterns Researched

### From `/Users/noid/hub/dev/portfolio/devops/.github/workflows/ec2-ecs-*.yml`

Borrow:

- PR workflow with app checks, Docker build, local smoke test, Terraform fmt/validate/plan, and PR comment.
- AWS OIDC with separate role ARNs per workflow capability.
- Main deployment workflow with preflight checks before AWS mutation.
- Push-or-reuse immutable image by `sha-${GITHUB_SHA}`.
- Manual destroy workflow guarded by GitHub environment.
- Matrix/detection ideas for later multi-component deploys.

Improve for NodCode:

- Use sticky PR plan comments instead of creating a new comment per run.
- Deploy by digest rather than only by immutable tag.
- Split task definition/service apply so migrations run before service update.

### From `/Users/noid/hub/dev/web-lf2/.github/workflows`

Borrow:

- Separate `ci`, `terraform-plan`, deploy, and destroy workflows.
- GitHub environments as both approval surface and IAM trust boundary.
- Queued deployment concurrency per environment.
- Reusable workflow/orchestrator pattern for later multi-service releases.
- Pin deploy-sensitive third-party actions by full SHA.
- Shared account-level GitHub OIDC provider plus environment-scoped deployment roles.

Adapt for NodCode:

- Use a single `deploy.yml` with a whitelisted environment resolver, initially allowing only `staging`.
- Avoid hidden GitHub variables for role ARNs in this milestone; keep role ARNs visible in workflow YAML.

## Current NodCode State

Existing relevant files:

```text
infra/
  catalog/modules/
    api-bootstrap/     # current env-local ECR repository
    api-service/       # currently owns ECS cluster, roles, ALB, task defs, service, app secret, logs
    database/          # RDS PostgreSQL + DB secret
    networking/        # VPC/subnets/routing/security groups
  catalog/units/
  live/staging/terragrunt.stack.hcl

tui/
  Dockerfile
  package.json
  packages/server/package.json
  packages/database/package.json
```

Current gaps to resolve:

- No `.github/workflows` in NodCode yet.
- `api-bootstrap` creates an environment-local mutable ECR repo; target is shared immutable repo.
- `api-service` is too coarse for a pre-service migration gate.
- `api-service` owns runtime secret and log group; target is persistent env bootstrap.
- Staging DB currently has `db_deletion_protection = true` and final snapshot behavior; target is disposable staging DB.
- Root package has no typecheck script yet; target adds typecheck only, not full lint/format tooling.

## Locked Design Decisions

1. **Scope**: staging first; design cleanly for future prod.
2. **OIDC roles**: split `plan`, `image-push`, and `apply` roles.
3. **Persistence boundary**: shared/bootstrap resources survive; staging runtime/data is disposable.
4. **Staging DB teardown**: deletion protection off, skip final snapshot on staging; comment that prod must not use this posture.
5. **Image repository**: shared ECR repository for API images.
6. **Image deployment**: ECS task definitions deploy by digest-pinned image URI.
7. **Bootstrap**: local manual bootstrap with AWS SSO/Terragrunt.
8. **Public repo PR trust**: AWS-backed plans only run for same-repo PRs.
9. **Migration gate**: migrations run before ECS service update.
10. **Terraform split**: split platform, taskdefs, and service units.
11. **Environment selection**: single deploy workflow with whitelisted environment resolver.
12. **Workflow files**: separate `ci.yml`, `terraform-plan.yml`, `deploy.yml`, `destroy-runtime.yml`.
13. **Plan comments**: sticky update comment per environment.
14. **Action pinning**: pin deploy-sensitive third-party actions by full SHA.
15. **Destroy guard**: typed confirmation such as `destroy-staging`.
16. **Image scanning**: report-only initially; do not block staging deploy.
17. **Smoke tests**: safe no-auth checks only.
18. **Path filters**: only app/infra/workflow changes trigger CI/deploy.
19. **Main deploy trigger**: deploy on `push` to `main` with preflight checks.
20. **CI checks**: add typecheck only; do not introduce lint/format stack yet.
21. **IaC engine**: Terraform + Terragrunt for this milestone.
22. **AWS IDs**: whitelisted workflow YAML role ARNs.
23. **Runtime secrets**: persistent environment bootstrap owns `api-runtime` secret.
24. **Logs**: persistent environment bootstrap owns CloudWatch log group.
25. **Egress**: keep NAT gateway for now; runtime destroy controls cost.
26. **ECR tags**: immutable `sha-*` tags; no mutable env aliases yet.
27. **PR plan scope**: staging runtime only.
28. **Concurrency**: queue deploys; cancel stale PR runs.

## Target Infrastructure Layout

Recommended end state:

```text
infra/
  catalog/modules/
    github-oidc-provider/        # account-level OIDC provider
    api-image-repository/        # shared ECR repository: devops-nodcode-api
    deployment-identity/         # env-scoped GitHub OIDC roles/policies
    api-env-bootstrap/           # env persistent app secret shell + log group
    networking/                  # runtime
    database/                    # runtime
    api-platform/                # ECS cluster, roles, ALB/ACM/DNS/TG, no task defs/service
    api-taskdefs/                # web + migration task definitions for API_IMAGE_URI
    api-service/                 # ECS service consuming web task definition ARN
  catalog/units/
    github-oidc-provider/
    api-image-repository/
    deployment-identity/
    api-env-bootstrap/
    networking/
    database/
    api-platform/
    api-taskdefs/
    api-service/
  live/
    shared/terragrunt.stack.hcl
    staging/terragrunt.stack.hcl
```

### Persistent shared bootstrap

`infra/live/shared` should be applied manually from local AWS SSO. It owns:

- GitHub Actions OIDC provider for `https://token.actions.githubusercontent.com`.
- Shared ECR repo `devops-nodcode-api`.

### Persistent staging bootstrap

`infra/live/staging` should include manually applied bootstrap units that are not destroyed during cheap runtime teardown:

- `deployment-identity`: staging GitHub OIDC roles and policies.
- `api-env-bootstrap`: Secrets Manager API runtime secret shell and CloudWatch log group.

### Disposable staging runtime

Runtime units are deploy-managed and can be destroyed to save cost:

- `networking`
- `database`
- `api-platform`
- `api-taskdefs`
- `api-service`

## Infrastructure Implementation Details

### 1. Add shared ECR module

Create `api-image-repository` from the current `api-bootstrap` idea, but make it shared rather than environment-local.

Target repository:

```text
devops-nodcode-api
```

Required behavior:

- Scan on push enabled.
- Encryption enabled.
- Tag immutability enabled for SHA tags. Prefer full repository immutability if acceptable.
- Lifecycle policy keeps a bounded number of images, e.g. last 30-50 images.

Outputs:

- `repository_name`
- `repository_url`
- `repository_arn`

### 2. Add GitHub OIDC provider module

Create account-level provider once:

```hcl
resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = [
    "sts.amazonaws.com",
  ]

  thumbprint_list = []
}
```

This belongs in `infra/live/shared`.

### 3. Add deployment identity module

Create three staging roles:

```text
devops-nodcode-staging-github-plan
devops-nodcode-staging-github-image-push
devops-nodcode-staging-github-apply
```

Trust policies:

- Plan role:

```text
repo:noidilin/nodcode:pull_request
```

- Image push and apply roles:

```text
repo:noidilin/nodcode:environment:staging
```

All roles should include:

- `aud = sts.amazonaws.com`
- `max_session_duration = 3600`
- existing sandbox permissions boundary where required.

Policy scope:

- `plan`: read Terraform state/lock as required, read/describe AWS resources needed for staging runtime plans.
- `image-push`: ECR auth and image push actions only for shared API ECR repo.
- `apply`: manage staging runtime resources, run ECS migration task, pass only ECS task roles to `ecs-tasks.amazonaws.com`.

### 4. Add env bootstrap module

Move these resources out of current `api-service`:

- Secrets Manager secret: `devops-nodcode-staging/api-runtime`
- Initial non-sensitive secret version with empty values.
- CloudWatch log group: `/ecs/devops-nodcode-staging-api`

Do not put real Clerk/Polar/Sentry/fallback provider values in Terraform state. Continue writing real values out-of-band with `aws secretsmanager put-secret-value`.

### 5. Update database module for disposable staging

Add variable:

```hcl
variable "db_skip_final_snapshot" {
  description = "Whether to skip final DB snapshot on destroy. Staging may set true; prod should normally set false."
  type        = bool
  default     = false
}
```

Use it in `aws_db_instance`:

```hcl
skip_final_snapshot = var.db_skip_final_snapshot
```

For staging:

```hcl
# Staging is disposable to support cheap runtime teardown.
# Production must enable deletion protection and final snapshot/backup retention.
db_deletion_protection = false
db_skip_final_snapshot = true
```

### 6. Split `api-service` module

Current `api-service` owns too much. Split into three modules.

#### `api-platform`

Owns:

- ECS cluster.
- ECS execution role.
- ECS task role.
- Bedrock runtime IAM permissions.
- ALB, listeners, target group, ACM certificate, DNS record.
- Security attachment dependencies via inputs.

Consumes:

- networking outputs
- database secret ARN
- api runtime secret ARN
- log group name/ARN
- ECR repository URL if needed only for outputs; task definitions should consume full image URI elsewhere.

Outputs:

- `ecs_cluster_name`
- `ecs_cluster_arn`
- `ecs_execution_role_arn`
- `ecs_task_role_arn`
- `target_group_arn`
- `api_url`
- `private_app_subnet_ids`
- `ecs_security_group_id`
- `api_container_port`
- `health_check_path`

#### `api-taskdefs`

Owns:

- API web task definition.
- Database migration task definition.

Consumes:

- `api_image_uri` as a full digest-pinned image URI:

```text
ACCOUNT.dkr.ecr.REGION.amazonaws.com/devops-nodcode-api@sha256:...
```

- execution role ARN
- task role ARN
- database secret ARN
- runtime secret ARN
- log group name
- Bedrock env vars
- port/health check config

Outputs:

- `api_task_definition_arn`
- `migration_task_definition_arn`
- `container_name`

Important: both task definitions must use the exact same `api_image_uri`.

#### `api-service`

Owns:

- ECS service only.

Consumes:

- cluster name/ARN
- API task definition ARN
- target group ARN
- subnet IDs
- ECS security group ID
- container name/port

Outputs:

- `ecs_service_name`
- `ecs_cluster_name`
- `api_url`

### 7. Update Terragrunt stacks

`infra/live/shared/terragrunt.stack.hcl`:

```hcl
unit "github-oidc-provider" { ... }
unit "api-image-repository" { ... }
```

`infra/live/staging/terragrunt.stack.hcl`:

- Add `account_id = "549475122024"` if not already present.
- Add `github_repo = "noidilin/nodcode"`.
- Add `api_image_uri = get_env("API_IMAGE_URI", "...")`.
- Include units:
  - `deployment-identity`
  - `api-env-bootstrap`
  - `networking`
  - `database`
  - `api-platform`
  - `api-taskdefs`
  - `api-service`

PR and deploy workflows should exclude bootstrap units from automated runtime queues where possible.

## Application Script Changes

Add basic typecheck scripts. Do not introduce lint/format stack yet.

Recommended root `tui/package.json` additions:

```json
{
  "scripts": {
    "typecheck": "bunx tsc -p packages/server/tsconfig.json --noEmit && bunx tsc -p packages/cli/tsconfig.json --noEmit",
    "typecheck:server": "bunx tsc -p packages/server/tsconfig.json --noEmit",
    "typecheck:cli": "bunx tsc -p packages/cli/tsconfig.json --noEmit"
  }
}
```

CI should run existing tests/build/smoke plus this typecheck.

## Workflow Implementation Plan

Create:

```text
.github/workflows/ci.yml
.github/workflows/terraform-plan.yml
.github/workflows/deploy.yml
.github/workflows/destroy-runtime.yml
```

Use path filters:

```yaml
paths:
  - "tui/**"
  - "infra/**"
  - ".github/workflows/ci.yml"
  - ".github/workflows/terraform-plan.yml"
  - ".github/workflows/deploy.yml"
  - ".github/workflows/destroy-runtime.yml"
```

### `ci.yml`

Purpose: non-AWS quality gate for PRs and main pushes.

Triggers:

- `pull_request` to `main`
- `push` to `main`
- `workflow_dispatch`

Permissions:

```yaml
permissions:
  contents: read
```

Concurrency:

```yaml
concurrency:
  group: ci-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: true
```

Jobs:

1. `app-checks`
   - checkout with `persist-credentials: false`
   - setup Bun
   - `cd tui`
   - `bun install --frozen-lockfile`
   - `bun run typecheck`
   - `bun run test:server`
   - `bun run build:server`
   - `bun run build:cli`

2. `container-smoke`
   - checkout
   - setup Bun if needed by scripts
   - `cd tui`
   - `bun install --frozen-lockfile`
   - `bun run docker:build:server`
   - `bun run docker:smoke:server`

Notes:

- Keep this workflow free of AWS credentials.
- Fork PRs can safely run this workflow.

### `terraform-plan.yml`

Purpose: staging runtime infrastructure review for same-repo PRs.

Triggers:

- `pull_request` to `main` with relevant paths.

Permissions:

```yaml
permissions:
  id-token: write
  contents: read
  pull-requests: write
```

Concurrency:

```yaml
concurrency:
  group: terraform-plan-pr-${{ github.event.pull_request.number }}
  cancel-in-progress: true
```

Security guard:

```yaml
if: github.event.pull_request.head.repo.full_name == github.repository
```

Steps:

1. Checkout with `persist-credentials: false`.
2. Configure AWS credentials with:

```text
arn:aws:iam::549475122024:role/devops-nodcode-staging-github-plan
```

3. Setup Terraform/Terragrunt.
4. Run Terragrunt HCL format check:

```sh
terragrunt hcl format --check --diff --working-dir infra
```

5. Run Terraform format check:

```sh
find infra/catalog/modules -name "*.tf" -exec terraform fmt -check -diff {} \;
```

6. Validate staging runtime units.
7. Plan staging runtime units.

Plan command should exclude manually bootstrapped units:

- `deployment-identity`
- `api-env-bootstrap`
- possibly shared units, because those are not in the staging stack or not queued.

Use `API_IMAGE_URI` placeholder for plan if needed:

```text
API_IMAGE_URI=000000000000.dkr.ecr.ap-northeast-1.amazonaws.com/devops-nodcode-api@sha256:000...
```

8. Sticky comment PR plan.

Sticky marker:

```md
<!-- nodcode-terraform-plan:staging -->
```

Comment body should include:

- environment
- commit SHA
- plan output truncated to GitHub comment limits
- note that full plan is available as artifact if uploaded

### `deploy.yml`

Purpose: deploy main branch to staging and later support manual environment dispatch.

Triggers:

```yaml
on:
  push:
    branches: [main]
    paths: [...]
  workflow_dispatch:
    inputs:
      environment:
        description: "Environment to deploy"
        required: true
        type: choice
        options:
          - staging
```

Permissions:

```yaml
permissions:
  id-token: write
  contents: read
```

#### Job: `resolve-environment`

Outputs:

- `environment`
- `infra_dir`
- `aws_region`
- `plan_role_arn`
- `image_push_role_arn`
- `apply_role_arn`

Resolver rules:

- `push` to `main` always maps to `staging`.
- `workflow_dispatch` must match whitelist.
- Unknown environment fails before AWS auth.

Example whitelist:

```sh
case "$REQUESTED_ENV" in
  staging)
    echo "environment=staging" >> "$GITHUB_OUTPUT"
    echo "infra_dir=infra/live/staging" >> "$GITHUB_OUTPUT"
    echo "aws_region=ap-northeast-1" >> "$GITHUB_OUTPUT"
    echo "plan_role_arn=arn:aws:iam::549475122024:role/devops-nodcode-staging-github-plan" >> "$GITHUB_OUTPUT"
    echo "image_push_role_arn=arn:aws:iam::549475122024:role/devops-nodcode-staging-github-image-push" >> "$GITHUB_OUTPUT"
    echo "apply_role_arn=arn:aws:iam::549475122024:role/devops-nodcode-staging-github-apply" >> "$GITHUB_OUTPUT"
    ;;
  *)
    echo "Unsupported environment: $REQUESTED_ENV" >&2
    exit 1
    ;;
esac
```

#### Job: `preflight`

Uses no GitHub environment yet unless AWS plan is included in this job. Recommended checks:

- Same as `ci.yml` critical checks.
- Docker build + local smoke.
- Terraform/Terragrunt format, validate, and staging plan using plan role.

This duplicates some CI, but makes the deploy workflow self-contained and robust.

#### Job: `build-and-push-image`

Uses:

```yaml
environment: ${{ needs.resolve-environment.outputs.environment }}
```

This is required so OIDC trust sub matches:

```text
repo:noidilin/nodcode:environment:staging
```

Steps:

1. Checkout.
2. Configure AWS credentials using image-push role.
3. Get shared ECR repository URL/name. Options:
   - read known repo name from resolver and call `aws ecr describe-repositories`, or
   - read Terragrunt output from shared bootstrap if apply role can read it.
4. Build local image:

```sh
IMAGE_TAG="sha-${GITHUB_SHA}"
docker build -f tui/Dockerfile -t "nodcode-api:${IMAGE_TAG}" tui
```

5. Push if missing:

```sh
if aws ecr describe-images --repository-name "$REPO" --image-ids "imageTag=${IMAGE_TAG}" >/dev/null 2>&1; then
  echo "Reusing existing image ${IMAGE_TAG}"
else
  aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$REGISTRY"
  docker tag "nodcode-api:${IMAGE_TAG}" "${ECR_REPOSITORY_URL}:${IMAGE_TAG}"
  docker push "${ECR_REPOSITORY_URL}:${IMAGE_TAG}"
fi
```

6. Resolve digest:

```sh
DIGEST=$(aws ecr describe-images \
  --repository-name "$REPO" \
  --image-ids "imageTag=${IMAGE_TAG}" \
  --query 'imageDetails[0].imageDigest' \
  --output text)

API_IMAGE_URI="${ECR_REPOSITORY_URL}@${DIGEST}"
echo "api_image_uri=${API_IMAGE_URI}" >> "$GITHUB_OUTPUT"
```

7. Report ECR scan findings if available. Do not fail deployment on findings yet.

#### Job: `deploy-runtime`

Uses:

```yaml
environment: ${{ needs.resolve-environment.outputs.environment }}
concurrency:
  group: deploy-${{ needs.resolve-environment.outputs.environment }}
  cancel-in-progress: false
```

Steps:

1. Checkout.
2. Configure AWS credentials with apply role.
3. Setup Terraform/Terragrunt.
4. Export:

```sh
export API_IMAGE_URI='${{ needs.build-and-push-image.outputs.api_image_uri }}'
```

5. Apply platform dependencies if needed:

```sh
terragrunt stack run apply --non-interactive --tf-forward-stdout \
  --queue-include-dir '.terragrunt-stack/networking' \
  --queue-include-dir '.terragrunt-stack/database' \
  --queue-include-dir '.terragrunt-stack/api-platform' \
  --queue-strict-include
```

6. Apply task definitions:

```sh
terragrunt stack run apply --non-interactive --tf-forward-stdout \
  --queue-include-dir '.terragrunt-stack/api-taskdefs' \
  --queue-strict-include
```

7. Read migration task/network outputs:

- cluster name
- migration task definition ARN
- private app subnets
- ECS security group

8. Run migration task using the same digest-pinned task definition:

```sh
aws ecs run-task \
  --region "$AWS_REGION" \
  --cluster "$CLUSTER" \
  --launch-type FARGATE \
  --task-definition "$MIGRATION_TASK_DEFINITION" \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SECURITY_GROUPS],assignPublicIp=DISABLED}"
```

9. Wait for migration task to stop and verify exit code is `0`.

10. Apply ECS service:

```sh
terragrunt stack run apply --non-interactive --tf-forward-stdout \
  --queue-include-dir '.terragrunt-stack/api-service' \
  --queue-strict-include
```

11. Wait for ECS service stability:

```sh
aws ecs wait services-stable --cluster "$CLUSTER" --services "$SERVICE"
```

12. Safe smoke checks:

```sh
curl -fsS "$API_URL/health"
STATUS=$(curl -sS -o /tmp/sessions-response.txt -w "%{http_code}" "$API_URL/sessions" || true)
test "$STATUS" = "401"
```

Do not perform real Clerk, Polar, or Bedrock checks in automated staging deploy.

### `destroy-runtime.yml`

Purpose: manually destroy disposable staging runtime to save cost.

Triggers:

```yaml
workflow_dispatch:
  inputs:
    environment:
      type: choice
      options: [staging]
    confirmation:
      description: "Type destroy-staging"
      required: true
      type: string
```

Permissions:

```yaml
permissions:
  id-token: write
  contents: read
```

Guard:

```sh
if [ "$CONFIRMATION" != "destroy-staging" ]; then
  echo "Confirmation mismatch" >&2
  exit 1
fi
```

Use:

```yaml
environment: staging
concurrency:
  group: deploy-staging
  cancel-in-progress: false
```

Destroy only runtime units, in dependency-safe order:

1. `api-service`
2. `api-taskdefs` if Terraform destroy is useful; task definition revisions may remain in AWS but state should be cleaned if module owns them.
3. `api-platform`
4. `database`
5. `networking`

Do not destroy:

- `shared/github-oidc-provider`
- `shared/api-image-repository`
- `staging/deployment-identity`
- `staging/api-env-bootstrap`

## GitHub Environment Setup

Create GitHub environment:

```text
staging
```

For this milestone:

- No required reviewers needed for automatic main deploy unless desired.
- Environment is still required for OIDC trust boundary.

Future production environment:

```text
prod
```

Prod should require manual approval and should deploy an already-built digest from shared ECR.

## Manual Bootstrap Runbook Additions

Document these commands in the infra runbook after implementation.

Initial shared bootstrap:

```sh
cd infra/live/shared
terragrunt stack run apply --non-interactive
```

Initial staging persistent bootstrap:

```sh
cd infra/live/staging
terragrunt stack run apply --non-interactive --tf-forward-stdout \
  --queue-include-dir '.terragrunt-stack/deployment-identity' \
  --queue-include-dir '.terragrunt-stack/api-env-bootstrap' \
  --queue-strict-include
```

Write real staging API secrets out-of-band:

```sh
aws secretsmanager put-secret-value \
  --region ap-northeast-1 \
  --secret-id devops-nodcode-staging/api-runtime \
  --secret-string file://infra/secrets/staging.api-runtime.json
```

## Security Notes

- Never use `pull_request_target` for Terraform planning against PR code.
- AWS-backed PR plans run only when `github.event.pull_request.head.repo.full_name == github.repository`.
- Workflows use least permissions. Do not grant `contents: write` unless needed.
- All checkouts should set `persist-credentials: false`.
- Deploy-sensitive third-party actions should be pinned by full commit SHA during implementation.
- Runtime third-party secrets stay in AWS Secrets Manager; GitHub Actions does not receive Clerk/Polar/Sentry/API keys.
- ECR image push role should not have infrastructure apply permissions.
- Apply role should not have permission to push arbitrary images.

## Validation Plan

Before closing implementation:

1. Local scripts:

```sh
cd tui
bun install --frozen-lockfile
bun run typecheck
bun run test:server
bun run build:server
bun run build:cli
bun run docker:build:server
bun run docker:smoke:server
```

2. Terraform formatting:

```sh
terragrunt hcl format --check --diff --working-dir infra
find infra/catalog/modules -name "*.tf" -exec terraform fmt -check -diff {} \;
```

3. Bootstrap apply from local AWS SSO:

```sh
cd infra/live/shared && terragrunt stack run apply
cd ../staging && terragrunt stack run apply --queue-include-dir '.terragrunt-stack/deployment-identity' --queue-include-dir '.terragrunt-stack/api-env-bootstrap' --queue-strict-include
```

4. PR validation:

- Open same-repo PR changing app/infra.
- Confirm `ci.yml` runs.
- Confirm `terraform-plan.yml` assumes plan role and posts/updates one sticky comment.

5. Main deploy validation:

- Merge to main.
- Confirm deploy workflow resolves `staging`.
- Confirm image is pushed once and digest is resolved.
- Confirm task definitions reference `@sha256:` URI.
- Confirm migration task exits `0` before service update.
- Confirm ECS service stabilizes.
- Confirm smoke checks pass.

6. Destroy validation:

- Run `destroy-runtime.yml` with wrong confirmation and verify it fails.
- Run with `destroy-staging` and verify runtime resources are destroyed.
- Verify shared ECR, OIDC provider, deployment roles, runtime secret, and log group remain.

## Acceptance Criteria

- `.github/workflows/ci.yml` runs non-AWS checks for PRs and main pushes.
- `.github/workflows/terraform-plan.yml` runs only for same-repo PRs and posts a sticky staging plan comment.
- `.github/workflows/deploy.yml` deploys main to staging through AWS OIDC and GitHub environment trust.
- `.github/workflows/destroy-runtime.yml` destroys only staging runtime after typed confirmation.
- No workflow stores or uses long-lived AWS access keys.
- Shared ECR image is tagged `sha-${GITHUB_SHA}` and ECS deploys by digest-pinned URI.
- Database migration task runs and succeeds before ECS service update.
- Staging runtime can be destroyed without deleting OIDC provider, ECR repo, deployment roles, API runtime secret, or log group.
- Staging DB destroy skips final snapshot; documentation clearly states production must not copy that posture.
- Automated smoke tests avoid real Clerk, Polar, and Bedrock calls.

## Risks and Mitigations

| Risk | Mitigation |
| --- | --- |
| Public repo PR abuses AWS-backed plan | Same-repo PR guard; no `pull_request_target`. |
| Migration task and web service use different images | Both task definitions consume one digest-pinned `API_IMAGE_URI`. |
| ECS service updates before migration | Split `api-taskdefs` and `api-service`; workflow runs migration between applies. |
| Staging destroy deletes secrets/log history | Move runtime secret and log group into persistent env bootstrap. |
| Mutable image tag is overwritten | Shared ECR uses immutable SHA tags and ECS deploys by digest. |
| Terraform apply race | Deployment and destroy use same queued environment concurrency. |
| Comment spam on PRs | Sticky plan comment marker. |
| NAT cost while idle | Runtime destroy workflow removes VPC/NAT/ALB/ECS/RDS when not needed. |

## Suggested Implementation Order

1. Add typecheck scripts to `tui/package.json`.
2. Add shared `github-oidc-provider` and `api-image-repository` modules/units/stack.
3. Add staging `deployment-identity` module/unit.
4. Add staging `api-env-bootstrap` module/unit and move secret/log ownership out of `api-service`.
5. Add DB `db_skip_final_snapshot` variable and staging disposable DB comments/settings.
6. Split `api-service` into `api-platform`, `api-taskdefs`, and `api-service`.
7. Update Terragrunt dependencies/outputs for split units.
8. Add `ci.yml`.
9. Add `terraform-plan.yml` with same-repo guard and sticky comment.
10. Add `deploy.yml` with resolver, digest image push, migration gate, service apply, and smoke checks.
11. Add `destroy-runtime.yml` with typed confirmation.
12. Update runbooks with bootstrap, secret writing, deploy, migration, smoke, and destroy instructions.
13. Run local validation.
14. Apply local manual bootstrap.
15. Validate PR plan and main staging deploy end-to-end.
