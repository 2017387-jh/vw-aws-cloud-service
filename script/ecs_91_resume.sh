#!/usr/bin/env bash
set -euo pipefail
source .env
aws configure set region "$AWS_REGION"

BASE_TASKS="${DDN_ECS_DESIRED_COUNT:-${DDN_ECS_DESIRED_TASK_COUNT:-2}}"

echo "[RESUME] Resume ASG min/max (2~4)"
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name "$DDN_ASG_NAME" \
  --min-size "$DDN_MIN_CAPACITY" \
  --max-size "$DDN_MAX_CAPACITY" \
  --desired-capacity "$DDN_MIN_CAPACITY" >/dev/null

echo "[RESUME] Resume Scalable Target min/max (2~4)"
aws application-autoscaling register-scalable-target \
  --service-namespace ecs \
  --scalable-dimension ecs:service:DesiredCount \
  --resource-id service/$DDN_ECS_CLUSTER/$DDN_ECS_SERVICE \
  --min-capacity "$DDN_MIN_CAPACITY" \
  --max-capacity "$DDN_MAX_CAPACITY" >/dev/null

echo "[RESUME] Service DesiredCount -> $BASE_TASKS"
aws ecs update-service \
  --cluster "$DDN_ECS_CLUSTER" \
  --service "$DDN_ECS_SERVICE" \
  --desired-count "$BASE_TASKS" >/dev/null

echo "[RESUME] done."
