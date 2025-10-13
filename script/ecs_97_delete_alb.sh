#!/usr/bin/env bash
set -euo pipefail
source .env
aws configure set region "$AWS_REGION"

ALB_ARN=$(aws elbv2 describe-load-balancers --names "$DDN_ALB_NAME" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || echo "None")

if [ -n "$ALB_ARN" ] && [ "$ALB_ARN" != "None" ]; then
  echo "[INFO] Found ALB: $DDN_ALB_NAME ($ALB_ARN)"

  # (A) ALB에 연결된 TG를 ALB 삭제 전에 수집 (이것만 지우도록)
  TG_ARNS=$(aws elbv2 describe-target-groups --load-balancer-arn "$ALB_ARN" \
    --query 'TargetGroups[].TargetGroupArn' --output text 2>/dev/null || echo "")
  echo "[INFO] TargetGroups attached to ALB: ${TG_ARNS:-<none>}"

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

  # 3. ALB 삭제 완료 대기 (공식 waiter)
  echo "[INFO] Waiting for ALB deletion to complete..."
  aws elbv2 wait load-balancer-deleted --load-balancer-arns "$ALB_ARN"
  echo "[OK] ALB deletion confirmed."

  # 4. Target Group 삭제 (해당 ALB에 연결돼 있던 것만)
  if [ -n "${TG_ARNS:-}" ]; then
    echo "[INFO] Deleting Target Groups attached to ALB..."
    for TG in $TG_ARNS; do
      echo "[INFO] Deleting target group: $TG"
      aws elbv2 delete-target-group --target-group-arn "$TG" || true
    done
  else
    echo "[INFO] No Target Groups attached to ALB."
  fi
else
  echo "[INFO] ALB not found: $DDN_ALB_NAME"
fi

# 5. (선택) ALB 보안 그룹 삭제 - 다른 참조가 남아 있으면 실패할 수 있음
ALB_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$DDN_VPC_ID" "Name=group-name,Values=$DDN_ALB_SG_NAME" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")

if [ "$ALB_SG_ID" != "None" ]; then
  echo "[INFO] Deleting ALB security group: $ALB_SG_ID"
  aws ec2 delete-security-group --group-id "$ALB_SG_ID" || true
fi

echo "[✅ DONE] ALB, Listeners, TargetGroups, SG cleanup completed."
