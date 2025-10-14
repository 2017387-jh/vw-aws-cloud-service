#!/usr/bin/env bash
set -euo pipefail
source .env
aws configure set region "$AWS_REGION"

# 현재 Task Definition의 최신 리비전 가져오기
REV=$(aws ecs describe-task-definition \
  --task-definition "$DDN_ECS_TASK_FAMILY" \
  --query 'taskDefinition.revision' \
  --output text)

echo "[INFO] Updating service '$DDN_ECS_SERVICE' on cluster '$DDN_ECS_CLUSTER' to use task definition revision $REV ..."

aws ecs update-service \
  --cluster "$DDN_ECS_CLUSTER" \
  --service "$DDN_ECS_SERVICE" \
  --task-definition "$DDN_ECS_TASK_FAMILY:$REV" \
  --force-new-deployment \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS_JSON],securityGroups=[\"$ECS_SG_ID\"],assignPublicIp=ENABLED}" \
  --desired-count "$DDN_ECS_DESIRED_COUNT" \
  >/dev/null

# 배포 진행 상황 확인 (선택)
aws ecs describe-services \
  --cluster "$DDN_ECS_CLUSTER" \
  --services "$DDN_ECS_SERVICE" \
  --query "services[0].deployments" \
  --output table

echo "[OK] Service '$DDN_ECS_SERVICE' updated to revision $REV (new deployment started)"
