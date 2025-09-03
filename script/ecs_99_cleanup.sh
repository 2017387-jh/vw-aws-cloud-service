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
aws ec2 delete-launch-template --launch-template-name "$DDN_LAUNCH_TEMPLATE_NAME"

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

aws ecs delete-capacity-provider --capacity-provider "${DDN_ASG_NAME}-cp" 2>/dev/null

set -e
echo "[OK] Cleanup done."
