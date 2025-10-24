#!/usr/bin/env bash
set -euo pipefail
source .env
aws configure set region "$AWS_REGION"

# ALB / Target Group
ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names "$DDN_ALB_NAME" \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text)

TG_FLASK_ARN=$(aws elbv2 describe-target-groups \
  --names "$DDN_TG_FLASK" \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text)

# gRPC Target Group ARN 조회
TG_GRPC_ARN=$(aws elbv2 describe-target-groups \
  --names "${DDN_TG_GRPC:-ddn-tg-grpc}" \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text)

  echo "[INFO] Creating ECS Service '$DDN_ECS_SERVICE' on cluster '$DDN_ECS_CLUSTER' ..."
  echo " Flask TG ARN: $TG_FLASK_ARN"
  echo " gRPC TG ARN: $TG_GRPC_ARN"
  
# 보안 그룹, 서브넷
ECS_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$DDN_VPC_ID" "Name=group-name,Values=$DDN_ECS_SG_NAME" \
  --query 'SecurityGroups[0].GroupId' --output text)

SUBNETS_JSON=$(printf '"%s",' ${DDN_SUBNET_IDS//,/ } | sed 's/,$//')

# 최신 리비전
REV=$(aws ecs list-task-definitions \
  --family-prefix "$DDN_ECS_TASK_FAMILY" \
  --sort DESC --query 'taskDefinitionArns[0]' --output text)

# ECS 서비스 생성 (Flask + gRPC 모두 ALB 연결)
aws ecs create-service \
  --cluster "$DDN_ECS_CLUSTER" \
  --service-name "$DDN_ECS_SERVICE" \
  --task-definition "$REV" \
  --desired-count "$DDN_ECS_DESIRED_TASK_COUNT" \
  --launch-type EC2 \
  --placement-constraints type=distinctInstance \
  --placement-strategy type=spread,field=attribute:ecs.availability-zone \
  --load-balancers \
      "targetGroupArn=$TG_FLASK_ARN,containerName=$DDN_ECS_CONTAINER,containerPort=$DDN_FLASK_HTTP_PORT" \
      "targetGroupArn=$TG_GRPC_ARN,containerName=$DDN_ECS_CONTAINER,containerPort=$DDN_FLASK_GRPC_PORT" \
  --health-check-grace-period-seconds 60 \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS_JSON],securityGroups=[\"$ECS_SG_ID\"],assignPublicIp=DISABLED}" \
  --query '{Service:service.serviceName,Status:service.status,LoadBalancers:service.loadBalancers}' \
  --output json
  || { echo "[ERROR] Failed to create ECS Service"; exit 1; }

# ALB DNS 확인
DNS=$(aws elbv2 describe-load-balancers \
  --names "$DDN_ALB_NAME" \
  --query 'LoadBalancers[0].DNSName' --output text)

echo "[OK] Service created. ALB DNS: http://$DNS"
echo " - Flask: http://$DNS/"
echo " - gRPC : http://$DNS/denoising.DenoisingService/Ping (ALB HTTP/2 라우팅)"