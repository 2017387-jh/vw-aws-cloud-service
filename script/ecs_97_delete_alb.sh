#!/usr/bin/env bash
set -euo pipefail
source .env
aws configure set region "$AWS_REGION"

ALB_ARN=$(aws elbv2 describe-load-balancers --names "$DDN_ALB_NAME" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null)

if [ -n "$ALB_ARN" ] && [ "$ALB_ARN" != "None" ]; then
  echo "[INFO] Found ALB: $DDN_ALB_NAME ($ALB_ARN)"
  LISTENERS=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
    --query 'Listeners[].ListenerArn' --output text)
  for L in $LISTENERS; do
    echo "[INFO] Deleting listener: $L"
    aws elbv2 delete-listener --listener-arn "$L"
  done
  echo "[INFO] Deleting ALB: $DDN_ALB_NAME"
  aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN"
  echo "[OK] ALB deleted: $DDN_ALB_NAME"
else
  echo "[INFO] ALB not found: $DDN_ALB_NAME"
fi