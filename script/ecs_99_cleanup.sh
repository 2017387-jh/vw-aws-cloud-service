#!/usr/bin/env bash
set -euo pipefail
source .env
aws configure set region "$AWS_REGION"

set +e
aws ecs update-service --cluster "$DDN_ECS_CLUSTER" --service "$DDN_ECS_SERVICE" --desired-count 0
aws ecs delete-service --cluster "$DDN_ECS_CLUSTER" --service "$DDN_ECS_SERVICE" --force

aws autoscaling update-auto-scaling-group --auto-scaling-group-name "$DDN_ASG_NAME" --min-size 0 --desired-capacity 0
sleep 10
aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "$DDN_ASG_NAME" --force-delete

LT_NAME="$DDN_LAUNCH_TEMPLATE_NAME"
LT_ID=$(aws ec2 describe-launch-templates \
  --launch-template-names "$LT_NAME" \
  --query 'LaunchTemplates[0].LaunchTemplateId' --output text 2>/dev/null)

if [ -n "$LT_ID" ] && [ "$LT_ID" != "None" ]; then
  aws ec2 delete-launch-template --launch-template-name "$LT_NAME"
  echo "[OK] Launch Template deleted: $LT_NAME"
else
  echo "[INFO] Launch Template not found: $LT_NAME"
fi

ALB_ARN=$(aws elbv2 describe-load-balancers --names "$DDN_ALB_NAME" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null)
if [ -n "$ALB_ARN" ]; then
  LISTENERS=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --query 'Listeners[].ListenerArn' --output text)
  for L in $LISTENERS; do aws elbv2 delete-listener --listener-arn "$L"; done
  aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN"
fi

for TG in "$DDN_TG_FLASK" "$DDN_TG_TRITON"; do
  TG_ARN=$(aws elbv2 describe-target-groups --names "$TG" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null)
  [ -n "$TG_ARN" ] && aws elbv2 delete-target-group --target-group-arn "$TG_ARN"
done

aws ecs delete-cluster --cluster "$DDN_ECS_CLUSTER"
aws logs delete-log-group --log-group-name "/ecs/$DDN_ECS_TASK_FAMILY"

ECS_SG_ID=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$DDN_VPC_ID" "Name=group-name,Values=$DDN_ECS_SG_NAME" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
ALB_SG_ID=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$DDN_VPC_ID" "Name=group-name,Values=$DDN_ALB_SG_NAME" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
[ "$ECS_SG_ID" != "None" ] && aws ec2 delete-security-group --group-id "$ECS_SG_ID"
[ "$ALB_SG_ID" != "None" ] && aws ec2 delete-security-group --group-id "$ALB_SG_ID"

# Detach capacity provider from cluster first
if aws ecs describe-clusters --clusters "$DDN_ECS_CLUSTER" --query 'clusters[0].status' --output text 2>/dev/null | grep -q "ACTIVE"; then
  aws ecs put-cluster-capacity-providers \
    --cluster "$DDN_ECS_CLUSTER" \
    --capacity-providers [] \
    --default-capacity-provider-strategy [] \
    >/dev/null 2>&1 || true
fi

# Delete capacity provider
if aws ecs describe-capacity-providers --capacity-providers "${DDN_ASG_NAME}-cp" >/dev/null 2>&1; then
  aws ecs delete-capacity-provider --capacity-provider "${DDN_ASG_NAME}-cp"
  echo "[OK] Capacity Provider deleted: ${DDN_ASG_NAME}-cp"
else
  echo "[INFO] Capacity Provider not found: ${DDN_ASG_NAME}-cp"
fi

set -e
echo "[OK] Cleanup done."
