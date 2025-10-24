#!/usr/bin/env bash
set -euo pipefail

source .env
aws configure set region "$AWS_REGION"

echo "[INFO] Using region: $AWS_REGION"
echo "[INFO] Cluster: $DDN_ECS_CLUSTER, Service: $DDN_ECS_SERVICE"

# ------------------------------------------------------------------------------
# 1) ALB / Target Group 조회
# ------------------------------------------------------------------------------
ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names "$DDN_ALB_NAME" \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text)

if [ -z "${ALB_ARN:-}" ] || [ "$ALB_ARN" = "None" ]; then
  echo "[ERROR] ALB not found: $DDN_ALB_NAME"
  exit 1
fi

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

echo "[INFO] ALB ARN      : $ALB_ARN"
echo "[INFO] Flask TG ARN : $TG_FLASK_ARN"
echo "[INFO] gRPC  TG ARN : ${TG_GRPC_ARN:-<none>} (name: $TG_GRPC_NAME)"

# gRPC TG가 ALB 리스너에 연결되어 있는지 확인
TG_GRPC_LB_ARNS=""
if [ -n "${TG_GRPC_ARN:-}" ] && [ "$TG_GRPC_ARN" != "None" ]; then
  TG_GRPC_LB_ARNS=$(aws elbv2 describe-target-groups \
    --target-group-arns "$TG_GRPC_ARN" \
    --query 'TargetGroups[0].LoadBalancerArns' --output text 2>/dev/null || true)
fi
if [ -n "$TG_GRPC_LB_ARNS" ] && [ "$TG_GRPC_LB_ARNS" != "None" ]; then
  echo "[CHECK] gRPC TG is attached to LB(s): $TG_GRPC_LB_ARNS"
else
  echo "[WARN] gRPC TG is NOT attached to any load balancer listener. (Will skip adding it to the service)"
fi

# ------------------------------------------------------------------------------
# 2) 보안그룹 / 서브넷 / 최신 태스크 정의 리비전 조회
# ------------------------------------------------------------------------------
ECS_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$DDN_VPC_ID" "Name=group-name,Values=$DDN_ECS_SG_NAME" \
  --query 'SecurityGroups[0].GroupId' --output text)

if [ -z "${ECS_SG_ID:-}" ] || [ "$ECS_SG_ID" = "None" ]; then
  echo "[ERROR] ECS Security Group not found: $DDN_ECS_SG_NAME"
  exit 1
fi

SUBNETS_JSON=$(printf '"%s",' ${DDN_SUBNET_IDS//,/ } | sed 's/,$//')

REV=$(aws ecs list-task-definitions \
  --family-prefix "$DDN_ECS_TASK_FAMILY" \
  --sort DESC --query 'taskDefinitionArns[0]' --output text)

if [ -z "${REV:-}" ] || [ "$REV" = "None" ]; then
  echo "[ERROR] No task definition found for family: $DDN_ECS_TASK_FAMILY"
  exit 1
fi

echo "[INFO] Using task definition: $REV"
echo "[INFO] ECS SG: $ECS_SG_ID"
echo "[INFO] Subnets: $DDN_SUBNET_IDS"

# ------------------------------------------------------------------------------
# 3) --load-balancers 인자 구성 (Flask는 항상 포함, gRPC는 연결된 경우에만 포함)
# ------------------------------------------------------------------------------
LB_ARGS=("targetGroupArn=$TG_FLASK_ARN,containerName=$DDN_ECS_CONTAINER,containerPort=$DDN_FLASK_HTTP_PORT")

if [ -n "${TG_GRPC_ARN:-}" ] && [ "$TG_GRPC_ARN" != "None" ] \
   && [ -n "$TG_GRPC_LB_ARNS" ] && [ "$TG_GRPC_LB_ARNS" != "None" ]; then
  LB_ARGS+=("targetGroupArn=$TG_GRPC_ARN,containerName=$DDN_ECS_CONTAINER,containerPort=$DDN_FLASK_GRPC_PORT")
  echo "[INFO] Will attach BOTH Flask and gRPC target groups to the service."
else
  echo "[INFO] Will attach ONLY the Flask target group (gRPC skipped)."
fi

# ------------------------------------------------------------------------------
# 4) ECS 서비스 생성
# ------------------------------------------------------------------------------
echo "[INFO] Creating ECS Service '$DDN_ECS_SERVICE' on cluster '$DDN_ECS_CLUSTER' ..."
aws ecs create-service \
  --cluster "$DDN_ECS_CLUSTER" \
  --service-name "$DDN_ECS_SERVICE" \
  --task-definition "$REV" \
  --desired-count "$DDN_ECS_DESIRED_TASK_COUNT" \
  --launch-type EC2 \
  --placement-constraints type=distinctInstance \
  --placement-strategy type=spread,field=attribute:ecs.availability-zone \
  --load-balancers "${LB_ARGS[@]}" \
  --health-check-grace-period-seconds 60 \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS_JSON],securityGroups=[\"$ECS_SG_ID\"],assignPublicIp=DISABLED}" \
  --query '{Service:service.serviceName,Status:service.status,LoadBalancers:service.loadBalancers}' \
  --output json \
  || { echo "[ERROR] Failed to create ECS Service"; exit 1; }

# ------------------------------------------------------------------------------
# 5) 엔드포인트 안내
# ------------------------------------------------------------------------------
DNS=$(aws elbv2 describe-load-balancers \
  --names "$DDN_ALB_NAME" \
  --query 'LoadBalancers[0].DNSName' --output text)

echo "[OK] Service created. ALB DNS: $DNS"
echo " - Flask:  http://$DNS/"
if [ "${#LB_ARGS[@]}" -eq 2 ]; then
  echo " - gRPC :  https://$DNS/denoising.DenoisingService/Ping"
else
  echo " - gRPC :  (skipped; attach HTTPS listener + rule first, then update the service)"
fi
