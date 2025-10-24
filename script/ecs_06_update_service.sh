#!/usr/bin/env bash
set -euo pipefail

source .env
aws configure set region "$AWS_REGION"

echo "[INFO] Region: $AWS_REGION"
echo "[INFO] Cluster: $DDN_ECS_CLUSTER"
echo "[INFO] Service: $DDN_ECS_SERVICE"

# ------------------------------------------------------------------------------
# 1) Resolve latest ACTIVE task definition revision
# ------------------------------------------------------------------------------
REV=$(aws ecs describe-task-definition \
  --task-definition "$DDN_ECS_TASK_FAMILY" \
  --query 'taskDefinition.revision' \
  --output text)

if [ -z "${REV:-}" ] || [ "$REV" = "None" ]; then
  echo "[ERROR] No ACTIVE task definition for family: $DDN_ECS_TASK_FAMILY"
  exit 1
fi

echo "[INFO] Target task definition: $DDN_ECS_TASK_FAMILY:$REV"

# ------------------------------------------------------------------------------
# 2) Fetch Target Groups
# ------------------------------------------------------------------------------
TG_FLASK_ARN=$(aws elbv2 describe-target-groups \
  --names "$DDN_TG_FLASK" \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text)

if [ -z "${TG_FLASK_ARN:-}" ] || [ "$TG_FLASK_ARN" = "None" ]; then
  echo "[ERROR] Flask Target Group not found: $DDN_TG_FLASK"
  exit 1
fi

TG_GRPC_NAME="${DDN_TG_GRPC:-ddn-tg-grpc}"
TG_GRPC_ARN=$(aws elbv2 describe-target-groups \
  --names "$TG_GRPC_NAME" \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text 2>/dev/null || true)

echo "[INFO] Flask TG ARN : $TG_FLASK_ARN"
echo "[INFO] gRPC  TG ARN : ${TG_GRPC_ARN:-<none>} (name: $TG_GRPC_NAME)"

# Check if gRPC TG is attached to any ALB listener (must be HTTPS in ALB case)
TG_GRPC_LB_ARNS=""
if [ -n "${TG_GRPC_ARN:-}" ] && [ "$TG_GRPC_ARN" != "None" ]; then
  TG_GRPC_LB_ARNS=$(aws elbv2 describe-target-groups \
    --target-group-arns "$TG_GRPC_ARN" \
    --query 'TargetGroups[0].LoadBalancerArns' \
    --output text 2>/dev/null || true)
fi

if [ -n "$TG_GRPC_LB_ARNS" ] && [ "$TG_GRPC_LB_ARNS" != "None" ]; then
  echo "[CHECK] gRPC TG is attached to LB(s): $TG_GRPC_LB_ARNS"
else
  echo "[WARN] gRPC TG is NOT attached to any ALB listener. It will be skipped."
fi

# ------------------------------------------------------------------------------
# 3) Build --load-balancers (Flask always, gRPC only if attached)
# ------------------------------------------------------------------------------
LB_ARGS=("targetGroupArn=$TG_FLASK_ARN,containerName=$DDN_ECS_CONTAINER,containerPort=$DDN_FLASK_HTTP_PORT")

if [ -n "${TG_GRPC_ARN:-}" ] && [ "$TG_GRPC_ARN" != "None" ] \
   && [ -n "$TG_GRPC_LB_ARNS" ] && [ "$TG_GRPC_LB_ARNS" != "None" ]; then
  LB_ARGS+=("targetGroupArn=$TG_GRPC_ARN,containerName=$DDN_ECS_CONTAINER,containerPort=$DDN_FLASK_GRPC_PORT")
  echo "[INFO] Will update service with BOTH Flask and gRPC target groups."
else
  echo "[INFO] Will update service with ONLY the Flask target group."
fi

# ------------------------------------------------------------------------------
# 4) Update service (force new deployment)
# ------------------------------------------------------------------------------
echo "[INFO] Updating service '$DDN_ECS_SERVICE' on cluster '$DDN_ECS_CLUSTER' ..."
aws ecs update-service \
  --cluster "$DDN_ECS_CLUSTER" \
  --service "$DDN_ECS_SERVICE" \
  --task-definition "$DDN_ECS_TASK_FAMILY:$REV" \
  --desired-count "$DDN_ECS_DESIRED_TASK_COUNT" \
  --force-new-deployment \
  --load-balancers "${LB_ARGS[@]}" \
  >/dev/null

# ------------------------------------------------------------------------------
# 5) Show deployment status (optional)
# ------------------------------------------------------------------------------
aws ecs describe-services \
  --cluster "$DDN_ECS_CLUSTER" \
  --services "$DDN_ECS_SERVICE" \
  --query "services[0].deployments" \
  --output table

echo "[OK] Service '$DDN_ECS_SERVICE' updated to $DDN_ECS_TASK_FAMILY:$REV"
