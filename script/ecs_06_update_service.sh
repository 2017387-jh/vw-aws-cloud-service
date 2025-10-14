#!/usr/bin/env bash
set -euo pipefail
source .env
aws configure set region "$AWS_REGION"

# ===== 안전장치 & 보조 변수 =====
: "${DDN_ECS_CLUSTER:?DDN_ECS_CLUSTER is required}"
: "${DDN_ECS_SERVICE:?DDN_ECS_SERVICE is required}"
: "${DDN_ECS_TASK_FAMILY:?DDN_ECS_TASK_FAMILY is required}"
: "${DDN_VPC_ID:?DDN_VPC_ID is required}"
ASSIGN_PUBLIC="${ASSIGN_PUBLIC:-ENABLED}"   # ENABLED or DISABLED
DDN_ECS_DESIRED_COUNT="${DDN_ECS_DESIRED_COUNT:-1}"
DDN_ECS_SG_NAME="${DDN_ECS_SG_NAME:-ddn-ecs-sg}"

# 보안그룹 ID 조회 (이전에 생성한 이름 기준)
ECS_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$DDN_VPC_ID" "Name=group-name,Values=$DDN_ECS_SG_NAME" \
  --query 'SecurityGroups[0].GroupId' --output text)
if [[ -z "$ECS_SG_ID" || "$ECS_SG_ID" == "None" ]]; then
  echo "[ERROR] ECS SG not found in VPC $DDN_VPC_ID (name=$DDN_ECS_SG_NAME)"; exit 1
fi

# 서브넷 목록(.env에 DDN_SUBNET_IDS=subnet-a,subnet-b 형태 권장)
: "${DDN_SUBNET_IDS:?DDN_SUBNET_IDS is required (comma-separated subnet IDs)}"
SUBNETS_JSON=$(printf '"%s",' ${DDN_SUBNET_IDS//,/ } | sed 's/,$//')

# 최신 리비전 번호 조회
REV=$(aws ecs describe-task-definition \
  --task-definition "$DDN_ECS_TASK_FAMILY" \
  --query 'taskDefinition.revision' --output text)
if [[ -z "$REV" || "$REV" == "None" ]]; then
  echo "[ERROR] Failed to get task definition revision for $DDN_ECS_TASK_FAMILY"; exit 1
fi

echo "[INFO] Updating service '$DDN_ECS_SERVICE' to $DDN_ECS_TASK_FAMILY:$REV (assignPublicIp=$ASSIGN_PUBLIC)"
aws ecs update-service \
  --cluster "$DDN_ECS_CLUSTER" \
  --service "$DDN_ECS_SERVICE" \
  --task-definition "$DDN_ECS_TASK_FAMILY:$REV" \
  --force-new-deployment \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS_JSON],securityGroups=[\"$ECS_SG_ID\"],assignPublicIp=$ASSIGN_PUBLIC}" \
  --desired-count "$DDN_ECS_DESIRED_COUNT" >/dev/null

# 상태 확인
aws ecs describe-services \
  --cluster "$DDN_ECS_CLUSTER" \
  --services "$DDN_ECS_SERVICE" \
  --query "{assignPublicIp:services[0].networkConfiguration.awsvpcConfiguration.assignPublicIp,deployments:services[0].deployments}" \
  --output table

echo "[OK] Service '$DDN_ECS_SERVICE' updated to revision $REV"
