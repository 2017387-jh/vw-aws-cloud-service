#!/usr/bin/env bash
set -euo pipefail
source .env
aws configure set region "$AWS_REGION"

ALB_ARN=$(aws elbv2 describe-load-balancers --names "$DDN_ALB_NAME" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || echo "None")

if [ -n "$ALB_ARN" ] && [ "$ALB_ARN" != "None" ]; then
  echo "[INFO] Found ALB: $DDN_ALB_NAME ($ALB_ARN)"

  # 1. Listener 삭제
  LISTENERS=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
    --query 'Listeners[].ListenerArn' --output text 2>/dev/null || echo "")
  for L in $LISTENERS; do
    echo "[INFO] Deleting listener: $L"
    aws elbv2 delete-listener --listener-arn "$L" || true
  done

  # 2. ALB 삭제
  echo "[INFO] Deleting ALB: $DDN_ALB_NAME"
  aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN"

  # 3. ALB 삭제 완료 대기
  echo "[INFO] Waiting for ALB deletion to complete..."
  for i in {1..20}; do
    ALB_STATE=$(aws elbv2 describe-load-balancers --names "$DDN_ALB_NAME" \
      --query 'LoadBalancers[0].State.Code' --output text 2>/dev/null || echo "deleted")
    if [ "$ALB_STATE" = "deleted" ] || [ "$ALB_STATE" = "None" ]; then
      echo "[OK] ALB deletion confirmed."
      break
    fi
    echo "[INFO] ALB state: $ALB_STATE ... waiting 10s"
    sleep 10
  done

else
  echo "[INFO] ALB not found: $DDN_ALB_NAME"
fi

# 4. Target Group 삭제
echo "[INFO] Deleting Target Groups..."
TGS=$(aws elbv2 describe-target-groups --query 'TargetGroups[].TargetGroupArn' --output text 2>/dev/null || echo "")
for TG in $TGS; do
  echo "[INFO] Deleting target group: $TG"
  aws elbv2 delete-target-group --target-group-arn "$TG" || true
done

# 5. (선택) ALB 보안 그룹 삭제
ALB_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$DDN_VPC_ID" "Name=group-name,Values=$DDN_ALB_SG_NAME" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")

if [ "$ALB_SG_ID" != "None" ]; then
  echo "[INFO] Deleting ALB security group: $ALB_SG_ID"
  aws ec2 delete-security-group --group-id "$ALB_SG_ID" || true
fi

echo "[✅ DONE] ALB, Listener, TargetGroup, SG cleanup completed."
