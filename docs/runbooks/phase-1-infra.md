# AWS control-plane runbook

This runbook covers the Terragrunt stack in `infra/live/staging` and the feature modules in `infra/catalog/modules/{networking,api-bootstrap,database,api-service}`.

## What it provisions

- VPC with public ALB subnets, private ECS subnets, and private database subnets.
- ECR repository for the NodCode API image.
- ECS Fargate cluster, task definition, and service in private subnets with `awsvpc` networking.
- Internet-facing ALB with Route53 DNS alias, DNS-validated ACM certificate, HTTPS listener, `/health` target checks, and `300s` idle timeout for chat streaming.
- RDS PostgreSQL in private subnets, not publicly reachable.
- Secrets Manager entries for database credentials and ECS-injected API runtime config.
- CloudWatch log group for container logs.
- Separate ECS execution and task roles with sandbox-approved `devops-*` names and the pre-existing `lab-devops-permissions-boundary`. The execution role pulls images, writes logs, and reads injected secrets. The task role grants Bedrock runtime invokes for the approved model scope.
- Security groups so users reach the API only through the ALB, ECS accepts traffic only from the ALB, and Postgres accepts traffic only from ECS tasks.

## Human review required before apply

Issue #6 is HITL. Review these before applying:

1. AWS account and `aws_region` in `infra/live/staging/terragrunt.stack.hcl`.
2. Route53 `hosted_zone_name` and `api_domain`; staging currently provisions `staging.nodcode.noidilin.dev` in the `noidilin.dev` public zone.
3. ACM certificate validation is managed by Terraform DNS records in Route53; the certificate is created in the same region as the ALB.
4. Cost choices: NAT gateway, RDS instance size, `desired_count`, and `db_multi_az`.
5. Security posture: `allowed_http_cidr_blocks`, database deletion protection, and whether to add WAF early.
6. Sandbox prerequisites: `lab-devops-permissions-boundary` must already exist in the target account. GitHub OIDC deployment identity is deferred to Phase 2.
7. Bedrock model access in the target account/region for `deepseek.v3.2`.

## Validate and plan

```sh
terragrunt hcl format --check --diff --working-dir infra
find infra/catalog/modules -name "*.tf" -exec terraform fmt -check -diff {} \;

cd infra/live/staging
$EDITOR terragrunt.stack.hcl
terragrunt stack run validate
terragrunt stack run plan
```

## Apply

Only apply after owner review of the plan:

```sh
cd infra/live/staging
terragrunt stack run apply
```

## Configure runtime secrets

Terraform creates two Secrets Manager secrets with split ownership:

- `${name_prefix}/database`: Terraform-managed database connection values, including `DATABASE_URL`.
- `${name_prefix}/api-runtime`: human/CI-managed third-party runtime secrets. Terraform only writes a non-sensitive bootstrap version with empty strings so ECS can resolve the JSON keys on first deployment. Real API keys are written out-of-band, so they do not enter Terraform state.

After the first apply, copy the gitignored bootstrap template and fill in real values locally:

```sh
cp infra/secrets/staging.api-runtime.json.example infra/secrets/staging.api-runtime.json
$EDITOR infra/secrets/staging.api-runtime.json
```

Add only the ECS API server's human/CI-managed secret values to `infra/secrets/staging.api-runtime.json`:

- `CLERK_SECRET_KEY`
- `CLERK_PUBLISHABLE_KEY`
- `POLAR_ACCESS_TOKEN`
- `POLAR_PRODUCT_ID`
- `POLAR_CREDITS_METER_ID`
- `POLAR_SERVER` (`sandbox` for staging unless you intentionally point at production Polar)
- optional `SENTRY_DSN`
- optional fallback provider keys: `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`
- optional `AWS_BEARER_TOKEN_BEDROCK` only if the app explicitly needs bearer-token Bedrock auth

Do not mirror every key from `tui/.env.example` into this secret:

- `DATABASE_URL` comes from `${name_prefix}/database`.
- `HOST`, `PORT`, `NODE_ENV`, `BEDROCK_AWS_REGION`, and `BEDROCK_CHAT_MODEL_ID` are non-secret ECS environment variables managed by Terraform.
- `API_URL`, `CLERK_FRONTEND_API`, and `CLERK_OAUTH_CLIENT_ID` are local CLI/client configuration, not ECS API server secrets.

Write the JSON into Secrets Manager out-of-band:

```sh
aws secretsmanager put-secret-value \
  --region ap-northeast-1 \
  --secret-id devops-nodcode-staging/api-runtime \
  --secret-string file://infra/secrets/staging.api-runtime.json
```

Do not commit `infra/secrets/staging.api-runtime.json`. It is ignored by `.gitignore`.

Secret changes are injected only at ECS task launch, so force a new ECS deployment after updates:

```sh
aws ecs update-service \
  --region ap-northeast-1 \
  --cluster devops-nodcode-staging-cluster \
  --service devops-nodcode-staging-api \
  --force-new-deployment
```

## Build and push the API image

After apply, get the ECR URL from the generated bootstrap unit directory:

```sh
cd infra/live/staging/.terragrunt-stack/api-bootstrap
ECR_REPOSITORY_URL=$(terragrunt output -raw ecr_repository_url)
```

From `tui/`:

```sh
aws ecr get-login-password --region ap-northeast-1 \
  | docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.ap-northeast-1.amazonaws.com"

docker buildx build \
  --platform linux/amd64 \
  -f Dockerfile \
  -t "$ECR_REPOSITORY_URL:staging" \
  --push \
  .
```

Then set `image_tag = "staging"` in `infra/live/staging/terragrunt.stack.hcl`, rerun `terragrunt stack run plan`, and apply the ECS task definition update. CI/CD should later replace this with immutable Git SHA tags.

## Run database migrations

Schema changes are deployed with Prisma migrations, not ad hoc SQL or `prisma db push`. The API image includes `packages/database/prisma/migrations` and the Prisma CLI, and Terraform registers a separate one-off ECS task definition with no web health check: `${name_prefix}-database-migration`.

Run migrations after the database exists and before verifying routes that read or write sessions. Do not print `DATABASE_URL`; ECS injects it from `${name_prefix}/database` at task launch.

```sh
CLUSTER=devops-nodcode-staging-cluster
SERVICE=devops-nodcode-staging-api
TASK_DEFINITION=devops-nodcode-staging-database-migration
SUBNETS=$(aws ecs describe-services \
  --region ap-northeast-1 \
  --cluster "$CLUSTER" \
  --services "$SERVICE" \
  --query 'services[0].networkConfiguration.awsvpcConfiguration.subnets' \
  --output text | tr '\t' ',')
SECURITY_GROUPS=$(aws ecs describe-services \
  --region ap-northeast-1 \
  --cluster "$CLUSTER" \
  --services "$SERVICE" \
  --query 'services[0].networkConfiguration.awsvpcConfiguration.securityGroups' \
  --output text | tr '\t' ',')

aws ecs run-task \
  --region ap-northeast-1 \
  --cluster "$CLUSTER" \
  --launch-type FARGATE \
  --task-definition "$TASK_DEFINITION" \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SECURITY_GROUPS],assignPublicIp=DISABLED}"
```

Check the migration task exit code in ECS and CloudWatch. A successful run prints Prisma migration status without revealing credentials. To inspect status without applying changes, override the command with `db:migrate:status`:

```sh
aws ecs run-task \
  --region ap-northeast-1 \
  --cluster "$CLUSTER" \
  --launch-type FARGATE \
  --task-definition "$TASK_DEFINITION" \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SECURITY_GROUPS],assignPublicIp=DISABLED}" \
  --overrides '{"containerOverrides":[{"name":"migration","command":["bun","run","--cwd","packages/database","db:migrate:status"]}]}'
```

If an environment was manually patched before migrations existed, `migrate deploy` can fail with Prisma `P3005` because tables already exist but `_prisma_migrations` does not. First confirm the live schema matches `20260611000000_init_sessions/migration.sql`, then mark only that initial migration as applied:

```sh
aws ecs run-task \
  --region ap-northeast-1 \
  --cluster "$CLUSTER" \
  --launch-type FARGATE \
  --task-definition "$TASK_DEFINITION" \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SECURITY_GROUPS],assignPublicIp=DISABLED}" \
  --overrides '{"containerOverrides":[{"name":"migration","command":["bun","run","--cwd","packages/database","db:migrate:resolve:init"]}]}'
```

After the resolve task succeeds, rerun the normal migration task. Fresh environments should not use the resolve command.

The Terraform-managed database secret includes `sslmode=require`; the API image also adds the AWS RDS global CA bundle via `NODE_EXTRA_CA_CERTS` so Postgres TLS is verified by the runtime instead of using `sslmode=no-verify`.

## Smoke check

After apply, migration, and ECS health stabilization:

```sh
API_URL="https://staging.nodcode.noidilin.dev"
TOKEN=$(jq -r .token "${XDG_CONFIG_HOME:-$HOME/.config}/nodcode/auth.json")

curl -fsS "$API_URL/health"
curl -i -H "Authorization: Bearer $TOKEN" "$API_URL/sessions"
curl -i \
  -H "Authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' \
  -d '{"title":"migration verification"}' \
  "$API_URL/sessions"
```

Expected results: `/health` returns 200, `GET /sessions` returns 200 with a JSON list, and `POST /sessions` returns 201 with a created session when the account has sufficient Polar credits.

Avoid real Bedrock chat smoke tests by default; use the manual Bedrock validation notes in `docs/plan/phase-1-bedrock.md` when you intentionally want to spend tokens.
