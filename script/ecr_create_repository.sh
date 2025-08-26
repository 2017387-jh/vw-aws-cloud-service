#!/usr/bin/env bash
set -euo pipefail
source .env
aws configure set region "$AWS_REGION"

aws ecr create-repository --repository-name "$DDN_ECR_REPO" || true
aws ecr describe-repositories --repository-names "$DDN_ECR_REPO" \
  --query "repositories[0].repositoryUri" --output text
