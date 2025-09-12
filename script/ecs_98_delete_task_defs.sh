#!/usr/bin/env bash
set -euo pipefail
source .env
aws configure set region "$AWS_REGION"

echo "[INFO] Deregistering all task definitions for family: $DDN_ECS_TASK_FAMILY"

# 해당 family의 모든 task definition ARN 조회
TASK_DEFS=$(aws ecs list-task-definitions \
  --family-prefix "$DDN_ECS_TASK_FAMILY" \
  --query 'taskDefinitionArns' \
  --output text 2>/dev/null)

if [ -z "$TASK_DEFS" ]; then
  echo "[INFO] No task definitions found for family: $DDN_ECS_TASK_FAMILY"
  exit 0
fi

# 하나씩 deregister
for TD in $TASK_DEFS; do
  ARN=$(aws ecs deregister-task-definition \
          --task-definition "$TD" \
          --query 'taskDefinition.taskDefinitionArn' \
          --output text)
  echo "[OK] Deregistered $ARN"
done

echo "[OK] All task definitions for $DDN_ECS_TASK_FAMILY deleted."