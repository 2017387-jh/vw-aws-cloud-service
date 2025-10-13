#!/usr/bin/env bash
set -euo pipefail
source .env

# === add: .env 키-값 upsert ===
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

echo "[INFO] Checking if API Gateway already exists: $DDN_APIGW_NAME"

# 0. Check existing API
EXISTING_API_ID=$(aws apigatewayv2 get-apis \
  --query "Items[?Name=='$DDN_APIGW_NAME'].ApiId" \
  --output text)

## If exists, update ALB integration and exit
if [[ -n "$EXISTING_API_ID" ]]; then
  echo "[INFO] API Gateway '$DDN_APIGW_NAME' already exists with ID: $EXISTING_API_ID"

  # Find ALB integration with ID
  ALB_INTEG_ID=$(aws apigatewayv2 get-integrations \
    --api-id "$EXISTING_API_ID" \
    --query "Items[?IntegrationType=='HTTP_PROXY'].IntegrationId" \
    --output text)

  if [[ -n "$ALB_INTEG_ID" ]]; then
    echo "[INFO] Updating ALB integration ($ALB_INTEG_ID) with new DNS: $DDN_ALB_DNS"
    aws apigatewayv2 update-integration \
      --api-id "$EXISTING_API_ID" \
      --integration-id "$ALB_INTEG_ID" \
      --integration-uri "http://$DDN_ALB_DNS" >/dev/null
    echo "[OK] ALB integration updated."
  else
    echo "[WARN] No existing ALB integration found. Creating new one..."
    aws apigatewayv2 create-integration \
      --api-id "$EXISTING_API_ID" \
      --integration-type HTTP_PROXY \
      --integration-uri "http://$DDN_ALB_DNS" \
      --integration-method ANY \
      --payload-format-version 1.0 >/dev/null
  fi

  ENDPOINT="https://${EXISTING_API_ID}.execute-api.${AWS_REGION}.amazonaws.com"
  echo "[INFO] API Gateway endpoint:"
  echo "$ENDPOINT"

  # === add: .env 갱신 ===
  upsert_env "DDN_APIGW_ENDPOINT" "$ENDPOINT"
  exit 0
fi

echo "[INFO] Creating API Gateway: $DDN_APIGW_NAME"

# 1. Create API
API_ID=$(aws apigatewayv2 create-api \
  --name "$DDN_APIGW_NAME" \
  --protocol-type HTTP \
  --query 'ApiId' \
  --output text)

echo "[INFO] API Gateway created with ID: $API_ID"

# 2. Lambda integration (presign)
LAMBDA_INTEG_ID=$(aws apigatewayv2 create-integration \
  --api-id "$API_ID" \
  --integration-type AWS_PROXY \
  --integration-uri "arn:aws:lambda:${AWS_REGION}:${ACCOUNT_ID}:function:${DDN_LAMBDA_FUNC_NAME}" \
  --payload-format-version 2.0 \
  --query 'IntegrationId' --output text)

# 3. ALB integration (Flask ECS)
ALB_URL="http://$DDN_ALB_DNS"
ALB_INTEG_ID=$(aws apigatewayv2 create-integration \
  --api-id "$API_ID" \
  --integration-type HTTP_PROXY \
  --integration-uri "$ALB_URL" \
  --integration-method ANY \
  --payload-format-version 1.0 \
  --query 'IntegrationId' --output text)

echo "[INFO] ALB URL: $ALB_URL"
echo "[INFO] ALB Integration ID: $ALB_INTEG_ID"

# 4. Routes
aws apigatewayv2 create-route --api-id "$API_ID" --route-key "GET /presign"  --target integrations/"$LAMBDA_INTEG_ID"
aws apigatewayv2 create-route --api-id "$API_ID" --route-key "POST /presign" --target integrations/"$LAMBDA_INTEG_ID"
aws apigatewayv2 create-route --api-id "$API_ID" --route-key "GET /ping"    --target integrations/"$ALB_INTEG_ID"
aws apigatewayv2 create-route --api-id "$API_ID" --route-key "POST /invocations" --target integrations/"$ALB_INTEG_ID"

echo "[INFO] Routes created."

# 5. Add Lambda permission
aws lambda add-permission \
  --function-name "$DDN_LAMBDA_FUNC_NAME" \
  --statement-id apigateway-access \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:${AWS_REGION}:${ACCOUNT_ID}:${API_ID}/*/*" >/dev/null

# 6. Deploy ($default는 리터럴)
aws apigatewayv2 create-stage \
  --api-id "$API_ID" \
  --stage-name '$default' \
  --auto-deploy >/dev/null

ENDPOINT="https://${API_ID}.execute-api.${AWS_REGION}.amazonaws.com"
echo "[INFO] API Gateway deployed to stage: $DDN_APIGW_NAME/\$default"
echo "[INFO] API Gateway endpoint:"
echo "$ENDPOINT"

# === add: 신규 생성 후도 .env 갱신 ===
upsert_env "DDN_APIGW_ENDPOINT" "$ENDPOINT"
