#!/usr/bin/env bash
set -euo pipefail
source .env
aws configure set region "$AWS_REGION"

aws logs create-log-group --log-group-name "/ecs/$DDN_ECS_TASK_FAMILY" >/dev/null 2>/dev/null || true

# 템플릿 치환
envsubst < taskdef.json.tpl > taskdef.json
cat taskdef.json | jq .

REV=$(aws ecs register-task-definition --cli-input-json file://taskdef.json --query 'taskDefinition.revision' --output text)
echo "[OK] Task definition registered: $DDN_ECS_TASK_FAMILY:$REV"
