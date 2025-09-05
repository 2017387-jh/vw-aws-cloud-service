#!/usr/bin/env bash
set -euo pipefail
source .env
aws configure set region "$AWS_REGION"

REV=$(aws ecs describe-task-definition --task-definition "$DDN_ECS_TASK_FAMILY" --query 'taskDefinition.revision' --output text)
aws ecs update-service \
  --cluster "$DDN_ECS_CLUSTER" \
  --service "$DDN_ECS_SERVICE" \
  --task-definition "$DDN_ECS_TASK_FAMILY:$REV" >/dev/null

echo "[OK] Service updated to revision $REV"
