#!/usr/bin/env bash
set -euo pipefail
source .env

# ===== helpers =====
upsert_env () {
  local KEY="$1"
  local VALUE="$2"
  if grep -qE "^${KEY}=" .env; then
    sed -i "s|^${KEY}=.*|${KEY}=${VALUE}|" .env
  else
    echo "${KEY}=${VALUE}" >> .env
  fi
  echo "[INFO] .env updated: ${KEY}=${VALUE}"
}

# .env 경로 변수
PRESIGN_PATH="${DDN_APIGW_PRESIGN_PATH}"
PING_PATH="${DDN_APIGW_PING_PATH}"
INVOC_PATH="${DDN_APIGW_INVOCATIONS_PATH}"

ALB_BASE="http://${DDN_ALB_DNS}"
ALB_PING_URI="${ALB_BASE}${PING_PATH}"
ALB_INVOC_URI="${ALB_BASE}${INVOC_PATH}"

echo "[INFO] Checking if API Gateway already exists: $DDN_APIGW_NAME"

EXISTING_API_ID=$(aws apigatewayv2 get-apis \
  --query "Items[?Name=='$DDN_APIGW_NAME'].ApiId" \
  --output text)

if [[ -n "${EXISTING_API_ID}" ]]; then
  echo "[INFO] API exists: ${EXISTING_API_ID}"

  # --- 통합 upsert (/ping) ---
  PING_INTEG_ID=$(aws apigatewayv2 get-integrations --api-id "${EXISTING_API_ID}" \
    --query "Items[?IntegrationType=='HTTP_PROXY' && contains(IntegrationUri, '${PING_PATH}')].IntegrationId" \
    --output text | tr -d '\n')
  if [[ -n "${PING_INTEG_ID}" && "${PING_INTEG_ID}" != "None" ]]; then
    echo "[INFO] Update /ping integration: ${PING_INTEG_ID} -> ${ALB_PING_URI}"
    aws apigatewayv2 update-integration \
      --api-id "${EXISTING_API_ID}" \
      --integration-id "${PING_INTEG_ID}" \
      --integration-uri "${ALB_PING_URI}" >/dev/null
  else
    echo "[INFO] Create /ping integration -> ${ALB_PING_URI}"
    PING_INTEG_ID=$(aws apigatewayv2 create-integration \
      --api-id "${EXISTING_API_ID}" \
      --integration-type HTTP_PROXY \
      --integration-method ANY \
      --integration-uri "${ALB_PING_URI}" \
      --payload-format-version 1.0 \
      --query 'IntegrationId' --output text)
  fi

  # --- 통합 upsert (/invocations) ---
  INVOC_INTEG_ID=$(aws apigatewayv2 get-integrations --api-id "${EXISTING_API_ID}" \
    --query "Items[?IntegrationType=='HTTP_PROXY' && contains(IntegrationUri, '${INVOC_PATH}')].IntegrationId" \
    --output text | tr -d '\n')
  if [[ -n "${INVOC_INTEG_ID}" && "${INVOC_INTEG_ID}" != "None" ]]; then
    echo "[INFO] Update /invocations integration: ${INVOC_INTEG_ID} -> ${ALB_INVOC_URI}"
    aws apigatewayv2 update-integration \
      --api-id "${EXISTING_API_ID}" \
      --integration-id "${INVOC_INTEG_ID}" \
      --integration-uri "${ALB_INVOC_URI}" >/dev/null
  else
    echo "[INFO] Create /invocations integration -> ${ALB_INVOC_URI}"
    INVOC_INTEG_ID=$(aws apigatewayv2 create-integration \
      --api-id "${EXISTING_API_ID}" \
      --integration-type HTTP_PROXY \
      --integration-method ANY \
      --integration-uri "${ALB_INVOC_URI}" \
      --payload-format-version 1.0 \
      --query 'IntegrationId' --output text)
  fi

  # --- 라우트 upsert (GET {PING_PATH}) ---
  PING_ROUTE_ID=$(aws apigatewayv2 get-routes --api-id "${EXISTING_API_ID}" \
    --query "Items[?RouteKey=='GET ${PING_PATH}'].RouteId" --output text | tr -d '\n')
  if [[ -n "${PING_ROUTE_ID}" && "${PING_ROUTE_ID}" != "None" ]]; then
    aws apigatewayv2 update-route \
      --api-id "${EXISTING_API_ID}" \
      --route-id "${PING_ROUTE_ID}" \
      --target "integrations/${PING_INTEG_ID}" >/dev/null
  else
    aws apigatewayv2 create-route \
      --api-id "${EXISTING_API_ID}" \
      --route-key "GET ${PING_PATH}" \
      --target "integrations/${PING_INTEG_ID}" >/dev/null
  fi

  # --- 라우트 upsert (POST {INVOC_PATH}) ---
  INVOC_ROUTE_ID=$(aws apigatewayv2 get-routes --api-id "${EXISTING_API_ID}" \
    --query "Items[?RouteKey=='POST ${INVOC_PATH}'].RouteId" --output text | tr -d '\n')
  if [[ -n "${INVOC_ROUTE_ID}" && "${INVOC_ROUTE_ID}" != "None" ]]; then
    aws apigatewayv2 update-route \
      --api-id "${EXISTING_API_ID}" \
      --route-id "${INVOC_ROUTE_ID}" \
      --target "integrations/${INVOC_INTEG_ID}" >/dev/null
  else
    aws apigatewayv2 create-route \
      --api-id "${EXISTING_API_ID}" \
      --route-key "POST ${INVOC_PATH}" \
      --target "integrations/${INVOC_INTEG_ID}" >/dev/null
  fi

  ENDPOINT="https://${EXISTING_API_ID}.execute-api.${AWS_REGION}.amazonaws.com"
  echo "[INFO] API Gateway endpoint: ${ENDPOINT}"
  upsert_env "DDN_APIGW_ENDPOINT" "${ENDPOINT}"
  exit 0
fi

echo "[INFO] Creating API Gateway: ${DDN_APIGW_NAME}"

# --- API 생성 ---
API_ID=$(aws apigatewayv2 create-api \
  --name "${DDN_APIGW_NAME}" \
  --protocol-type HTTP \
  --query 'ApiId' \
  --output text)
echo "[INFO] API created: ${API_ID}"

# --- Lambda 통합 (presign) ---
LAMBDA_INTEG_ID=$(aws apigatewayv2 create-integration \
  --api-id "${API_ID}" \
  --integration-type AWS_PROXY \
  --integration-uri "arn:aws:lambda:${AWS_REGION}:${ACCOUNT_ID}:function:${DDN_LAMBDA_FUNC_NAME}" \
  --payload-format-version 2.0 \
  --query 'IntegrationId' --output text)

# --- ALB 통합 (경로별) ---
PING_INTEG_ID=$(aws apigatewayv2 create-integration \
  --api-id "${API_ID}" \
  --integration-type HTTP_PROXY \
  --integration-method ANY \
  --integration-uri "${ALB_PING_URI}" \
  --payload-format-version 1.0 \
  --query 'IntegrationId' --output text)

INVOC_INTEG_ID=$(aws apigatewayv2 create-integration \
  --api-id "${API_ID}" \
  --integration-type HTTP_PROXY \
  --integration-method ANY \
  --integration-uri "${ALB_INVOC_URI}" \
  --payload-format-version 1.0 \
  --query 'IntegrationId' --output text)

echo "[INFO] ALB integrations: PING=${PING_INTEG_ID}, INVOC=${INVOC_INTEG_ID}"

# --- 라우트 생성 (.env 경로 사용) ---
aws apigatewayv2 create-route --api-id "${API_ID}" --route-key "GET ${PRESIGN_PATH}"  --target integrations/"${LAMBDA_INTEG_ID}" >/dev/null
aws apigatewayv2 create-route --api-id "${API_ID}" --route-key "POST ${PRESIGN_PATH}" --target integrations/"${LAMBDA_INTEG_ID}" >/dev/null
aws apigatewayv2 create-route --api-id "${API_ID}" --route-key "GET ${PING_PATH}"     --target integrations/"${PING_INTEG_ID}" >/dev/null
aws apigatewayv2 create-route --api-id "${API_ID}" --route-key "POST ${INVOC_PATH}"   --target integrations/"${INVOC_INTEG_ID}" >/dev/null
echo "[INFO] Routes created."

# --- Lambda permission ---
aws lambda add-permission \
  --function-name "${DDN_LAMBDA_FUNC_NAME}" \
  --statement-id apigateway-access \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:${AWS_REGION}:${ACCOUNT_ID}:${API_ID}/*/*" >/dev/null

# --- Stage 배포 ---
aws apigatewayv2 create-stage \
  --api-id "${API_ID}" \
  --stage-name "${DDN_APIGW_STAGE_NAME}" \
  --auto-deploy >/dev/null

upsert_env "DDN_APIGW_ID" "${API_ID}"
upsert_env "DDN_APIGW_PING_INTEG_ID" "${PING_INTEG_ID}"
upsert_env "DDN_APIGW_INVOC_INTEG_ID" "${INVOC_INTEG_ID}"
upsert_env "DDN_APIGW_LAMBDA_INTEG_ID" "${LAMBDA_INTEG_ID}"

ENDPOINT="https://${API_ID}.execute-api.${AWS_REGION}.amazonaws.com"
echo "[INFO] Deployed: ${DDN_APIGW_NAME}/${DDN_APIGW_STAGE_NAME}"
echo "[INFO] Endpoint: ${ENDPOINT}"
upsert_env "DDN_APIGW_ENDPOINT" "${ENDPOINT}"

