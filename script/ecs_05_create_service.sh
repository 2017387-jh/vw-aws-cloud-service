#!/usr/bin/env bash
set -euo pipefail
source .env
aws configure set region "$AWS_REGION"

ALB_ARN=$(aws elbv2 describe-load-balancers --names "$DDN_ALB_NAME" --query 'LoadBalancers[0].LoadBalancerArn' --output text)
TG_FLASK_ARN=$(aws elbv2 describe-target-groups --names "$DDN_TG_FLASK" --query 'TargetGroups[0].TargetGroupArn' --output text)
TG_TRITON_ARN=$(aws elbv2 describe-target-groups --names "$DDN_TG_TRITON" --query 'TargetGroups[0].TargetGroupArn' --output text)

# 보안그룹, 서브넷
ECS_SG_ID=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$DDN_VPC_ID" "Name=group-name,Values=$DDN_ECS_SG_NAME" --query 'SecurityGroups[0].GroupId' --output text)
SUBNETS_JSON=$(printf '"%s",' ${DDN_SUBNET_IDS//,/ } | sed 's/,$//')

# 최신 리비전
REV=$(aws ecs describe-task-definition --task-definition "$DDN_ECS_TASK_FAMILY" --query 'taskDefinition.revision' --output text)

aws ecs create-service \
  --cluster "$DDN_ECS_CLUSTER" \
  --service-name "$DDN_ECS_SERVICE" \
  --task-definition "$DDN_ECS_TASK_FAMILY:$REV" \
  --desired-count "$DDN_ECS_DESIRED_COUNT" \
  --launch-type EC2 \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS_JSON],securityGroups=[\"$ECS_SG_ID\"],assignPublicIp=DISABLED}" \
  --load-balancers "targetGroupArn=$TG_FLASK_ARN,containerName=$DDN_ECS_CONTAINER,containerPort=$DDN_FLASK_PORT" \
                  "targetGroupArn=$TG_TRITON_ARN,containerName=$DDN_ECS_CONTAINER,containerPort=$DDN_TRITON_GRPC_PORT" \
  --health-check-grace-period-seconds 60 >/dev/null

DNS=$(aws elbv2 describe-load-balancers --names "$DDN_ALB_NAME" --query 'LoadBalancers[0].DNSName' --output text)
echo "[OK] Service created. ALB DNS: http://$DNS"
echo " - Flask:        http://$DNS/"
echo " - Triton gRPC:  http://$DNS/triton  (HTTP/2 gRPC client 필요, 실제 gRPC는 ALB HTTP/2 경유)"
