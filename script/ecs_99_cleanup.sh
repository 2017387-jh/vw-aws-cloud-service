#!/usr/bin/env bash
set -euo pipefail
source .env
aws configure set region "$AWS_REGION"

set +e
aws ecs update-service --cluster "$DDN_ECS_CLUSTER" --service "$DDN_ECS_SERVICE" --desired-count 0
aws ecs delete-service --cluster "$DDN_ECS_CLUSTER" --service "$DDN_ECS_SERVICE" --force

aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name "$DDN_ASG_NAME" \
  --min-size 0 --desired-capacity 0

sleep 10
aws autoscaling delete-auto-scaling-group \
  --auto-scaling-group-name "$DDN_ASG_NAME" \
  --force-delete

# Launch Template 삭제
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

# ALB 삭제
ALB_ARN=$(aws elbv2 describe-load-balancers --names "$DDN_ALB_NAME" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null)
if [ -n "$ALB_ARN" ]; then
  LISTENERS=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
    --query 'Listeners[].ListenerArn' --output text)
  for L in $LISTENERS; do aws elbv2 delete-listener --listener-arn "$L"; done
  aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN"
fi

# Target Groups 삭제
for TG in "$DDN_TG_FLASK" "$DDN_TG_TRITON"; do
  TG_ARN=$(aws elbv2 describe-target-groups --names "$TG" \
    --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null)
  [ -n "$TG_ARN" ] && aws elbv2 delete-target-group --target-group-arn "$TG_ARN"
done

# ECS 클러스터 삭제
aws ecs delete-cluster --cluster "$DDN_ECS_CLUSTER"

# 로그 그룹 삭제
aws logs delete-log-group --log-group-name "/ecs/$DDN_ECS_TASK_FAMILY"

# 보안 그룹 삭제
ECS_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$DDN_VPC_ID" "Name=group-name,Values=$DDN_ECS_SG_NAME" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
ALB_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$DDN_VPC_ID" "Name=group-name,Values=$DDN_ALB_SG_NAME" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)

[ "$ECS_SG_ID" != "None" ] && aws ec2 delete-security-group --group-id "$ECS_SG_ID"
[ "$ALB_SG_ID" != "None" ] && aws ec2 delete-security-group --group-id "$ALB_SG_ID"

# Capacity Provider Detach & 삭제
aws ecs put-cluster-capacity-providers \
  --cluster "$DDN_ECS_CLUSTER" \
  --capacity-providers [] \
  --default-capacity-provider-strategy [] \
  >/dev/null 2>&1 || true

aws ecs delete-capacity-provider --capacity-provider "${DDN_ASG_NAME}-cp" 2>/dev/null

# EC2 인스턴스 종료 대기
echo "[INFO] Waiting for EC2 instances to terminate..."
INSTANCE_IDS=$(aws ec2 describe-instances \
  --filters "Name=tag:aws:autoscaling:groupName,Values=$DDN_ASG_NAME" \
  --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null)

if [ -n "$INSTANCE_IDS" ]; then
  aws ec2 wait instance-terminated --instance-ids $INSTANCE_IDS
  echo "[OK] All instances terminated."
else
  echo "[INFO] No instances found."
fi

# Task Definition 삭제 (모든 revision 비활성화)
echo "[INFO] Deregistering all task definitions for family: $DDN_ECS_TASK_FAMILY"
TASK_DEFS=$(aws ecs list-task-definitions \
  --family-prefix $DDN_ECS_TASK_FAMILY \
  --query 'taskDefinitionArns' --output text)

for TD in $TASK_DEFS; do
  aws ecs deregister-task-definition --task-definition $TD
  echo "[OK] Deregistered $TD"
done


set -e
echo "[OK] Cleanup done."
