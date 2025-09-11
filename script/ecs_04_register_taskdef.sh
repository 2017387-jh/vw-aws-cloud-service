#!/usr/bin/env bash
set -euo pipefail
source .env
aws configure set region "$AWS_REGION"

echo "[INFO] Installing required packages (gettext, jq)..."
sudo yum install -y -q gettext jq

aws logs create-log-group --log-group-name "/ecs/$DDN_ECS_TASK_FAMILY" >/dev/null 2>/dev/null || true

# envsubst로 JSON 생성
envsubst < taskdef.json.tpl > taskdef.json

# JSON 검증
if ! jq empty taskdef.json >/dev/null 2>&1; then
  echo "[ERROR] taskdef.json is not valid JSON"
  exit 1
fi

# 필수 Role 변수 확인
: "${DDN_EXEC_ROLE_ARN:?Need to set DDN_EXEC_ROLE_ARN in .env}"

# Task Definition 등록
REV=$(aws ecs register-task-definition \
  --cli-input-json file://taskdef.json \
  --query 'taskDefinition.revision' --output text)

if [ -z "$REV" ] || [ "$REV" = "None" ]; then
  echo "[ERROR] Task definition registration failed"
  exit 1
fi

echo "[OK] Task definition registered: $DDN_ECS_TASK_FAMILY:$REV"