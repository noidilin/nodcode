#!/usr/bin/env bash
set -euo pipefail

AWS_REGION=${AWS_REGION:-ap-northeast-1}
ENVIRONMENT=${ENVIRONMENT:-stage}
NAME_PREFIX=${NAME_PREFIX:-devops-nodcode-${ENVIRONMENT}}
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
STAGE_DIR="$ROOT_DIR/infra/live/$ENVIRONMENT"

cd "$STAGE_DIR"
terragrunt stack generate

import_if_missing() {
  local unit_dir=$1
  local address=$2
  local import_id=$3

  if (cd "$unit_dir" && terragrunt state list 2>/dev/null | grep -qx "$address"); then
    echo "state ok: $unit_dir $address"
    return 0
  fi

  echo "importing: $unit_dir $address <- $import_id"
  (cd "$unit_dir" && terragrunt import "$address" "$import_id")
}

role_exists() {
  aws iam get-role --role-name "$1" >/dev/null 2>&1
}

policy_exists() {
  aws iam get-role-policy --role-name "$1" --policy-name "$2" >/dev/null 2>&1
}

PLAN_ROLE="${NAME_PREFIX}-github-plan"
IMAGE_PUSH_ROLE="${NAME_PREFIX}-github-image-push"
APPLY_ROLE="${NAME_PREFIX}-github-apply"

if role_exists "$PLAN_ROLE"; then
  import_if_missing ".terragrunt-stack/deployment-identity" "aws_iam_role.plan" "$PLAN_ROLE"
fi
if role_exists "$IMAGE_PUSH_ROLE"; then
  import_if_missing ".terragrunt-stack/deployment-identity" "aws_iam_role.image_push" "$IMAGE_PUSH_ROLE"
fi
if role_exists "$APPLY_ROLE"; then
  import_if_missing ".terragrunt-stack/deployment-identity" "aws_iam_role.apply" "$APPLY_ROLE"
fi

if policy_exists "$PLAN_ROLE" "${ENVIRONMENT}-plan"; then
  import_if_missing ".terragrunt-stack/deployment-identity" "aws_iam_role_policy.plan" "${PLAN_ROLE}:${ENVIRONMENT}-plan"
fi
if policy_exists "$IMAGE_PUSH_ROLE" "api-image-push"; then
  import_if_missing ".terragrunt-stack/deployment-identity" "aws_iam_role_policy.image_push" "${IMAGE_PUSH_ROLE}:api-image-push"
fi
if policy_exists "$APPLY_ROLE" "${ENVIRONMENT}-apply"; then
  import_if_missing ".terragrunt-stack/deployment-identity" "aws_iam_role_policy.apply" "${APPLY_ROLE}:${ENVIRONMENT}-apply"
fi

SECRET_NAME="${NAME_PREFIX}/api-runtime"
if SECRET_ARN=$(aws secretsmanager describe-secret --region "$AWS_REGION" --secret-id "$SECRET_NAME" --query ARN --output text 2>/dev/null); then
  import_if_missing ".terragrunt-stack/api-env-bootstrap" "aws_secretsmanager_secret.app" "$SECRET_ARN"

  CURRENT_VERSION_ID=$(aws secretsmanager describe-secret \
    --region "$AWS_REGION" \
    --secret-id "$SECRET_NAME" \
    --query 'VersionIdsToStages | keys(@)[?contains(`AWSCURRENT`, VersionIdsToStages[@])]' \
    --output text 2>/dev/null || true)

  # Fallback for AWS CLI JMESPath limitations: inspect JSON with Python if available.
  if [[ -z "$CURRENT_VERSION_ID" || "$CURRENT_VERSION_ID" == "None" ]]; then
    CURRENT_VERSION_ID=$(aws secretsmanager describe-secret --region "$AWS_REGION" --secret-id "$SECRET_NAME" --output json \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next((k for k,v in d.get("VersionIdsToStages",{}).items() if "AWSCURRENT" in v), ""))' 2>/dev/null || true)
  fi

  if [[ -n "$CURRENT_VERSION_ID" && "$CURRENT_VERSION_ID" != "None" ]]; then
    import_if_missing ".terragrunt-stack/api-env-bootstrap" \
      "aws_secretsmanager_secret_version.app_bootstrap" \
      "${SECRET_ARN}|${CURRENT_VERSION_ID}"
  fi
fi

LOG_GROUP="/ecs/${NAME_PREFIX}-api"
if aws logs describe-log-groups --region "$AWS_REGION" --log-group-name-prefix "$LOG_GROUP" \
  --query "logGroups[?logGroupName=='${LOG_GROUP}'].logGroupName | [0]" --output text | grep -qx "$LOG_GROUP"; then
  import_if_missing ".terragrunt-stack/api-env-bootstrap" "aws_cloudwatch_log_group.api" "$LOG_GROUP"
fi

terragrunt stack run apply --non-interactive --tf-forward-stdout \
  --filter deployment-identity \
  --filter api-env-bootstrap

terragrunt stack run output --non-interactive --no-color \
  --filter deployment-identity \
  --filter api-env-bootstrap
