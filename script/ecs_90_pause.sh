#!/usr/bin/env bash
set -euo pipefail
source .env
aws configure set region "$AWS_REGION"

echo "[PAUSE] Scale service to 0"
aws ecs update-service \
  --cluster "$DDN_ECS_CLUSTER" \
  --service "$DDN_ECS_SERVICE" \
  --desired-count 0 >/dev/null

# Polling until runningCount and pendingCount are 0
for i in {1..12}; do
  S=$(aws ecs describe-services --cluster "$DDN_ECS_CLUSTER" --services "$DDN_ECS_SERVICE" \
      --query 'services[0].{running:runningCount,pending:pendingCount,status:status}' --output json)
  echo "[PAUSE] status: $S"
  RUN=$(echo "$S" | sed -n 's/.*"running": \([0-9]*\).*/\1/p')
  PEN=$(echo "$S" | sed -n 's/.*"pending": \([0-9]*\).*/\1/p')
  [ "${RUN:-0}" = "0" ] && [ "${PEN:-0}" = "0" ] && break
  sleep 10
done

echo "[PAUSE] Application Auto Scaling target min/max -> 0"
aws application-autoscaling register-scalable-target \
  --service-namespace ecs \
  --scalable-dimension ecs:service:DesiredCount \
  --resource-id service/$DDN_ECS_CLUSTER/$DDN_ECS_SERVICE \
  --min-capacity 0 \
  --max-capacity 0 >/dev/null

echo "[PAUSE] ASG min/desired -> 0"
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name "$DDN_ASG_NAME" \
  --min-size 0 --desired-capacity 0 >/dev/null

echo "[PAUSE] done."
