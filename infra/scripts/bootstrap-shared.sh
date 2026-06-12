#!/usr/bin/env bash
set -euo pipefail

AWS_REGION=${AWS_REGION:-ap-northeast-1}
REPO_NAME=${REPO_NAME:-devops-nodcode-api}
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SHARED_DIR="$ROOT_DIR/infra/live/shared"

cd "$SHARED_DIR"
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

OIDC_ARN=$(aws iam list-open-id-connect-providers \
  --query "OpenIDConnectProviderList[?contains(Arn, 'token.actions.githubusercontent.com')].Arn | [0]" \
  --output text)

if [[ -n "$OIDC_ARN" && "$OIDC_ARN" != "None" ]]; then
  import_if_missing ".terragrunt-stack/github-oidc-provider" \
    "aws_iam_openid_connect_provider.github" \
    "$OIDC_ARN"
fi

if aws ecr describe-repositories --region "$AWS_REGION" --repository-names "$REPO_NAME" >/dev/null 2>&1; then
  import_if_missing ".terragrunt-stack/api-image-repository" \
    "aws_ecr_repository.api" \
    "$REPO_NAME"

  if aws ecr get-lifecycle-policy --region "$AWS_REGION" --repository-name "$REPO_NAME" >/dev/null 2>&1; then
    import_if_missing ".terragrunt-stack/api-image-repository" \
      "aws_ecr_lifecycle_policy.api" \
      "$REPO_NAME"
  fi
fi

terragrunt stack run apply --non-interactive --tf-forward-stdout \
  --filter github-oidc-provider \
  --filter api-image-repository

terragrunt stack run output --non-interactive --no-color \
  --filter github-oidc-provider \
  --filter api-image-repository
