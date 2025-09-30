#!/usr/bin/env bash
set -euo pipefail
source .env
aws configure set region "$AWS_REGION"

# ALB SG
ALB_SG_ID=$(aws ec2 create-security-group \
  --vpc-id "$DDN_VPC_ID" \
  --group-name "$DDN_ALB_SG_NAME" \
  --description "ALB SG" \
  --query 'GroupId' --output text 2>/dev/null || true)
if [ -z "${ALB_SG_ID:-}" ]; then
  ALB_SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$DDN_VPC_ID" "Name=group-name,Values=$DDN_ALB_SG_NAME" \
    --query 'SecurityGroups[0].GroupId' --output text)
fi
echo "[INFO] ALB SG: $ALB_SG_ID"

# ALB SG 인바운드 80 공개
aws ec2 authorize-security-group-ingress --group-id "$ALB_SG_ID" \
  --ip-permissions "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0}]" >/dev/null 2>&1 || true

# ECS SG: ALB에서 오는 트래픽만 Flask 포트 허용
ECS_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$DDN_VPC_ID" "Name=group-name,Values=$DDN_ECS_SG_NAME" \
  --query 'SecurityGroups[0].GroupId' --output text)
if [ -z "$ECS_SG_ID" ] || [ "$ECS_SG_ID" = "None" ]; then
  echo "[ERROR] ECS Security Group not found. Run ecs_02 script first."
  exit 1
fi
echo "[INFO] ECS SG: $ECS_SG_ID"

# Flask 포트만 ALB SG에서 허용
aws ec2 authorize-security-group-ingress --group-id "$ECS_SG_ID" \
  --ip-permissions "IpProtocol=tcp,FromPort=$DDN_FLASK_PORT,ToPort=$DDN_FLASK_PORT,UserIdGroupPairs=[{GroupId=$ALB_SG_ID}]" >/dev/null 2>&1 || true

# Triton 포트는 외부 차단, 같은 ECS SG 내부 통신만 허용(Flask→Triton)
for P in "$DDN_TRITON_HTTP_PORT" "$DDN_TRITON_GRPC_PORT"; do
  aws ec2 authorize-security-group-ingress --group-id "$ECS_SG_ID" \
    --ip-permissions "IpProtocol=tcp,FromPort=$P,ToPort=$P,UserIdGroupPairs=[{GroupId=$ECS_SG_ID}]" >/dev/null 2>&1 || true
done

# ALB 생성
IFS=',' read -r SUBNET1 SUBNET2 <<< "$DDN_SUBNET_IDS"
ALB_ARN=$(aws elbv2 create-load-balancer \
  --name "$DDN_ALB_NAME" \
  --type application \
  --security-groups "$ALB_SG_ID" \
  --subnets "$SUBNET1" "$SUBNET2" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true)
if [ -z "${ALB_ARN:-}" ]; then
  ALB_ARN=$(aws elbv2 describe-load-balancers --names "$DDN_ALB_NAME" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text)
fi
echo "[INFO] ALB ARN: $ALB_ARN"

# Flask Target Group (Health Check 명시)
TG_FLASK_ARN=$(aws elbv2 create-target-group \
  --name "$DDN_TG_FLASK" \
  --protocol HTTP --port "$DDN_FLASK_PORT" \
  --vpc-id "$DDN_VPC_ID" \
  --target-type ip \
  --health-check-protocol HTTP \
  --health-check-path "$DDN_HEALTH_PATH" \
  --health-check-interval-seconds "$DDN_HEALTH_INTERVAL" \
  --health-check-timeout-seconds "$DDN_HEALTH_TIMEOUT" \
  --healthy-threshold-count "$DDN_HEALTH_HEALTHY" \
  --unhealthy-threshold-count "$DDN_HEALTH_UNHEALTHY" \
  --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true)
if [ -z "${TG_FLASK_ARN:-}" ]; then
  TG_FLASK_ARN=$(aws elbv2 describe-target-groups --names "$DDN_TG_FLASK" \
    --query 'TargetGroups[0].TargetGroupArn' --output text)
fi
echo "[INFO] TG Flask: $TG_FLASK_ARN"

# 리스너 80 → 기본 대상 Flask TG
LISTENER_ARN=$(aws elbv2 create-listener \
  --load-balancer-arn "$ALB_ARN" \
  --protocol HTTP --port 80 \
  --default-actions "Type=forward,TargetGroupArn=$TG_FLASK_ARN" \
  --query 'Listeners[0].ListenerArn' --output text 2>/dev/null || true)
if [ -z "${LISTENER_ARN:-}" ]; then
  LISTENER_ARN=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
    --query 'Listeners[0].ListenerArn' --output text)
fi

echo "[OK] ALB → Flask only. Triton is internal-only."

# ALB DNSName 가져오기
ALB_DNS=$(aws elbv2 describe-load-balancers --names "$DDN_ALB_NAME" \
  --query 'LoadBalancers[0].DNSName' --output text)

echo "[INFO] ALB DNS: $ALB_DNS"

# .env 파일 업데이트 (DDN_ALB_DNS 값 교체 or 추가)
if grep -q '^DDN_ALB_DNS=' .env; then
  # Windows 호환: 임시 파일 사용
  grep -v '^DDN_ALB_DNS=' .env > .env.tmp
  echo "DDN_ALB_DNS=$ALB_DNS" >> .env.tmp
  mv .env.tmp .env
  echo "[INFO] Updated existing DDN_ALB_DNS in .env"
else
  echo "" >> .env
  echo "DDN_ALB_DNS=$ALB_DNS" >> .env
  echo "[INFO] Added new DDN_ALB_DNS to .env"
fi

echo "[INFO] .env is now updated with DDN_ALB_DNS=$ALB_DNS"
