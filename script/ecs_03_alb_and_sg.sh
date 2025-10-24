#!/usr/bin/env bash
set -euo pipefail

# 환경 변수 로드
source .env

# 리전 설정
aws configure set region "${AWS_REGION}"

#############################################
# 1) ALB / SG 생성 및 규칙 설정
#############################################

# ALB 보안그룹 생성 또는 조회
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

# Authorize HTTP 80
aws ec2 authorize-security-group-ingress --group-id "$ALB_SG_ID" \
  --ip-permissions "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0}]" >/dev/null 2>&1 || true

# Authorize HTTPS 443
aws ec2 authorize-security-group-ingress --group-id "$ALB_SG_ID" \
  --ip-permissions "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0}]" >/dev/null 2>&1 || true

# ECS SG 조회 (먼저 ecs_02에서 만들어져 있어야 함)
ECS_SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$DDN_VPC_ID" "Name=group-name,Values=$DDN_ECS_SG_NAME" \
  --query 'SecurityGroups[0].GroupId' --output text)
if [ -z "$ECS_SG_ID" ] || [ "$ECS_SG_ID" = "None" ]; then
  echo "[ERROR] ECS Security Group not found. Run ecs_02 script first."
  exit 1
fi
echo "[INFO] ECS SG: $ECS_SG_ID"

# Flask 포트: ALB SG에서만 허용
aws ec2 authorize-security-group-ingress --group-id "$ECS_SG_ID" \
  --ip-permissions "IpProtocol=tcp,FromPort=$DDN_FLASK_HTTP_PORT,ToPort=$DDN_FLASK_HTTP_PORT,UserIdGroupPairs=[{GroupId=$ALB_SG_ID}]" >/dev/null 2>&1 || true

# gRPC 포트(FLASK_GRPC_PORT=50102)도 ALB SG에서만 허용
aws ec2 authorize-security-group-ingress --group-id "$ECS_SG_ID" \
  --ip-permissions "IpProtocol=tcp,FromPort=$DDN_FLASK_GRPC_PORT,ToPort=$DDN_FLASK_GRPC_PORT,UserIdGroupPairs=[{GroupId=$ALB_SG_ID}]" >/dev/null 2>&1 || true

# Triton 포트: 외부 차단, 같은 ECS SG 내부 통신만 허용
for P in "$DDN_TRITON_HTTP_PORT" "$DDN_TRITON_GRPC_PORT"; do
  aws ec2 authorize-security-group-ingress --group-id "$ECS_SG_ID" \
    --ip-permissions "IpProtocol=tcp,FromPort=$P,ToPort=$P,UserIdGroupPairs=[{GroupId=$ECS_SG_ID}]" >/dev/null 2>&1 || true
done

# ALB 생성 또는 조회
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

# Flask Target Group 생성 또는 조회 (Health Check 명시)
TG_FLASK_ARN=$(aws elbv2 create-target-group \
  --name "$DDN_TG_FLASK" \
  --protocol HTTP --port "$DDN_FLASK_HTTP_PORT" \
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

TG_GRPC_NAME="${DDN_TG_GRPC:-ddn-tg-grpc}"
TG_GRPC_ARN=$(aws elbv2 create-target-group \
  --name "$TG_GRPC_NAME" \
  --protocol HTTP --protocol-version GRPC \
  --port "$DDN_FLASK_GRPC_PORT" \
  --vpc-id "$DDN_VPC_ID" \
  --target-type ip \
  --health-check-protocol HTTP \
  --health-check-path "/denoising.DenoisingService/Ping" \
  --matcher GrpcCode=0 \
  --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true)

if [ -z "${TG_GRPC_ARN:-}" ] || [ "$TG_GRPC_ARN" = "None" ]; then
  TG_GRPC_ARN=$(aws elbv2 describe-target-groups --names "$TG_GRPC_NAME" \
    --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true)
fi

if [ -z "${TG_GRPC_ARN:-}" ] || [ "$TG_GRPC_ARN" = "None" ]; then
  echo "[ERROR] gRPC Target Group not found or creation failed: $TG_GRPC_NAME"
  exit 1
fi

echo "[INFO] TG gRPC: $TG_GRPC_ARN"

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

echo "[OK] ALB → Flask only. Listener ARN: $LISTENER_ARN"

# HTTPS(443) 리스너 생성 또는 조회
HTTPS_LISTENER_ARN=$(aws elbv2 create-listener \
  --load-balancer-arn "$ALB_ARN" \
  --protocol HTTPS --port 443 \
  --certificates CertificateArn="$ACM_CERT_ARN" \
  --default-actions "Type=forward,TargetGroupArn=$TG_FLASK_ARN" \
  --query 'Listeners[0].ListenerArn' --output text 2>/dev/null || true)

if [ -z "${HTTPS_LISTENER_ARN:-}" ] || [ "$HTTPS_LISTENER_ARN" = "None" ]; then
  HTTPS_LISTENER_ARN=$(aws elbv2 describe-listeners \
    --load-balancer-arn "$ALB_ARN" \
    --query 'Listeners[?Port==`443`].ListenerArn' --output text 2>/dev/null || true)
fi

if [ -z "${HTTPS_LISTENER_ARN:-}" ] || [ "$HTTPS_LISTENER_ARN" = "None" ]; then
  echo "[ERROR] HTTPS(443) listener not found/created. Check ACM_CERT_ARN and SG 443."
  exit 1
fi
echo "[INFO] HTTPS Listener: $HTTPS_LISTENER_ARN"

# gRPC 경로는 gRPC TG로 포워딩 (경로 기반: /denoising.DenoisingService/*)
# 우선순위 10 사용(겹치지 않게 조절 가능)
aws elbv2 create-rule \
  --listener-arn "$HTTPS_LISTENER_ARN" \
  --priority 10 \
  --conditions '[
    {"Field":"path-pattern","PathPatternConfig":{"Values":["/denoising.DenoisingService/*"]}}
  ]' \
  --actions "[{\"Type\":\"forward\",\"TargetGroupArn\":\"${TG_GRPC_ARN}\"}]" \
  >/dev/null 2>&1 || true
echo "[OK] gRPC path routing rule added on HTTPS listener."

GRPC_TG_LB_ARNS=$(aws elbv2 describe-target-groups \
  --target-group-arns "$TG_GRPC_ARN" \
  --query 'TargetGroups[0].LoadBalancerArns' --output text 2>/dev/null || true)

if [ -n "$GRPC_TG_LB_ARNS" ] && [ "$GRPC_TG_LB_ARNS" != "None" ]; then
  echo "[CHECK] gRPC TG attached to LB(s): $GRPC_TG_LB_ARNS"
else
  echo "[CHECK][NG] gRPC TG is NOT attached to any LB."
fi

# ALB DNSName
ALB_DNS=$(aws elbv2 describe-load-balancers --names "$DDN_ALB_NAME" \
  --query 'LoadBalancers[0].DNSName' --output text)
echo "[INFO] ALB DNS: $ALB_DNS"

# .env 파일의 DDN_ALB_DNS 업데이트 (Windows 호환)
if grep -q '^DDN_ALB_DNS=' .env; then
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
#############################################
# 2) API Gateway HTTP_PROXY(=ALB) 통합 URI 갱신
#############################################

# 스킴/베이스패스 유연화
ALB_SCHEME="${DDN_ALB_SCHEME:-http}"          # 필요 시 .env에 DDN_ALB_SCHEME=https
RAW_BASEPATH="${DDN_ALB_BASEPATH:-}"          # 필요 시 .env에 DDN_ALB_BASEPATH=/api 또는 api
# 베이스패스 정규화: 선행 슬래시 1개, 끝 슬래시 제거, 빈값이면 공백
if [ -n "$RAW_BASEPATH" ]; then
  ALB_BASEPATH="/${RAW_BASEPATH#/}"
  ALB_BASEPATH="${ALB_BASEPATH%/}"
else
  ALB_BASEPATH=""
fi

# 라우트 경로 지정(.env 없으면 기본값)
APIGW_HEALTH_ROUTE="${DDN_APIGW_HEALTH_ROUTE:-/healthz}"
ALB_HEALTH_PATH="${DDN_HEALTH_PATH:-/ping}"
INVOC_PATH="${DDN_APIGW_INVOCATIONS_PATH:-/invocations}"

if [ -z "${DDN_APIGW_NAME:-}" ]; then
  echo "[WARN] DDN_APIGW_NAME not set. Skip API Gateway update."
else
  echo "[INFO] Checking API Gateway for ALB URI update: $DDN_APIGW_NAME"

  EXISTING_API_ID=$(aws apigatewayv2 get-apis \
    --query "Items[?Name=='$DDN_APIGW_NAME'].ApiId" --output text 2>/dev/null || true)

  if [[ -z "$EXISTING_API_ID" || "$EXISTING_API_ID" == "None" ]]; then
    echo "[INFO] API Gateway not found. Skipping update."
  else
    echo "[INFO] Found API: $EXISTING_API_ID"

    # 2-1) GET {APIGW_HEALTH_ROUTE} 라우트의 통합 ID
    PING_TARGET=$(aws apigatewayv2 get-routes --api-id "$EXISTING_API_ID" \
      --query "Items[?RouteKey=='GET ${APIGW_HEALTH_ROUTE}'].Target" \
      --output text 2>/dev/null || true)
    PING_INTEG_ID="${PING_TARGET#integrations/}"

    # 2-2) POST {INVOC_PATH} 라우트의 통합 ID
    INVOC_TARGET=$(aws apigatewayv2 get-routes --api-id "$EXISTING_API_ID" \
      --query "Items[?RouteKey=='POST ${INVOC_PATH}'].Target" \
      --output text 2>/dev/null || true)
    INVOC_INTEG_ID="${INVOC_TARGET#integrations/}"

    # 2-3) 라우트별 완전한 통합 URI 구성
    # 예) http://<ALB_DNS>/<basepath>/ping
    NEW_URI_PING="${ALB_SCHEME}://${ALB_DNS}${ALB_BASEPATH}${ALB_HEALTH_PATH}"
    NEW_URI_INVOC="${ALB_SCHEME}://${ALB_DNS}${ALB_BASEPATH}${INVOC_PATH}"

    # 2-4) 통합 갱신
    if [[ -n "$PING_INTEG_ID" && "$PING_INTEG_ID" != "None" ]]; then
      echo "[INFO] Updating integration $PING_INTEG_ID (GET ${ALB_HEALTH_PATH}) -> $NEW_URI_PING"
      aws apigatewayv2 update-integration \
        --api-id "$EXISTING_API_ID" \
        --integration-id "$PING_INTEG_ID" \
        --integration-uri "$NEW_URI_PING" >/dev/null 2>&1 || {
          echo "[WARN] Failed to update integration $PING_INTEG_ID"
        }
    else
      echo "[WARN] GET ${ALB_HEALTH_PATH} route not found. Skipped."
    fi

    if [[ -n "$INVOC_INTEG_ID" && "$INVOC_INTEG_ID" != "None" ]]; then
      echo "[INFO] Updating integration $INVOC_INTEG_ID (POST ${INVOC_PATH}) -> $NEW_URI_INVOC"
      aws apigatewayv2 update-integration \
        --api-id "$EXISTING_API_ID" \
        --integration-id "$INVOC_INTEG_ID" \
        --integration-uri "$NEW_URI_INVOC" >/dev/null 2>&1 || {
          echo "[WARN] Failed to update integration $INVOC_INTEG_ID"
        }
    else
      echo "[WARN] POST ${INVOC_PATH} route not found. Skipped."
    fi

    echo "[OK] API Gateway integrations updated."

    # $default 스테이지 존재/AutoDeploy 보정
    STAGE_INFO=$(aws apigatewayv2 get-stages --api-id "$EXISTING_API_ID" \
      --query "Items[?StageName=='\$default'].AutoDeploy" --output text 2>/dev/null || true)

    if [[ -z "$STAGE_INFO" || "$STAGE_INFO" == "None" ]]; then
      echo "[INFO] Creating stage \$default with AutoDeploy=true"
      aws apigatewayv2 create-stage --api-id "$EXISTING_API_ID" --stage-name '$default' --auto-deploy >/dev/null
    elif [[ "$STAGE_INFO" != "true" ]]; then
      echo "[INFO] Enabling AutoDeploy on \$default stage"
      aws apigatewayv2 update-stage --api-id "$EXISTING_API_ID" --stage-name '$default' --auto-deploy >/dev/null
    fi

    echo "[INFO] API endpoint: https://${EXISTING_API_ID}.execute-api.${AWS_REGION}.amazonaws.com"
  fi
fi

echo "[DONE] ecs_03_alb_and_sg.sh complete."