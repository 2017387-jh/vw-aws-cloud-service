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

# ALB SG 인바운드 80 공개
aws ec2 authorize-security-group-ingress --group-id "$ALB_SG_ID" \
  --ip-permissions "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0}]" >/dev/null 2>&1 || true

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

# 스킴/베이스패스 유연화 (미설정 시 기본값)
ALB_SCHEME="${DDN_ALB_SCHEME:-http}"     # 필요 시 .env에 DDN_ALB_SCHEME=https
ALB_BASEPATH="${DDN_ALB_BASEPATH:-}"     # 필요 시 .env에 DDN_ALB_BASEPATH=/api
NEW_URI="${ALB_SCHEME}://${ALB_DNS}${ALB_BASEPATH}"

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

    # /ping, /invocations 라우트 타겟 수집
    ROUTE_TARGETS=$(aws apigatewayv2 get-routes --api-id "$EXISTING_API_ID" \
      --query "Items[?RouteKey=='GET /ping' || RouteKey=='POST /invocations'].Target" \
      --output text 2>/dev/null || true)

    # "integrations/xxx" → "xxx" 로 변환
    INTEG_IDS_FROM_ROUTES=""
    for T in $ROUTE_TARGETS; do
      IID=${T#integrations/}
      INTEG_IDS_FROM_ROUTES="$INTEG_IDS_FROM_ROUTES $IID"
    done

    # API 내 HTTP_PROXY 통합 ID들 수집
    HTTP_PROXY_IDS=$(aws apigatewayv2 get-integrations --api-id "$EXISTING_API_ID" \
      --query "Items[?IntegrationType=='HTTP_PROXY'].IntegrationId" \
      --output text 2>/dev/null || true)

    # 업데이트 대상 통합 ID = 라우트 참조 + HTTP_PROXY 유형의 합집합
    TO_UPDATE=$(echo "$INTEG_IDS_FROM_ROUTES $HTTP_PROXY_IDS" | tr ' ' '\n' | sort -u | tr '\n' ' ')

    if [[ -z "$TO_UPDATE" ]]; then
      echo "[WARN] No HTTP_PROXY integrations to update."
    else
      for INTEG_ID in $TO_UPDATE; do
        if [[ -n "$INTEG_ID" && "$INTEG_ID" != "None" ]]; then
          echo "[INFO] Updating integration $INTEG_ID → $NEW_URI"
          aws apigatewayv2 update-integration \
            --api-id "$EXISTING_API_ID" \
            --integration-id "$INTEG_ID" \
            --integration-uri "$NEW_URI" >/dev/null 2>&1 || {
              echo "[WARN] Failed to update integration $INTEG_ID"
            }
        fi
      done
      echo "[OK] API Gateway integrations updated."

      # $default 스테이지 존재/AutoDeploy 보정
      STAGE_INFO=$(aws apigatewayv2 get-stages --api-id "$EXISTING_API_ID" \
        --query "Items[?StageName=='$default'].AutoDeploy" --output text 2>/dev/null || true)

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
fi

echo "[DONE] ecs_03_alb_and_sg.sh complete."
