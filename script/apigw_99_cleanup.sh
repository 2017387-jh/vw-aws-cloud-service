#!/usr/bin/env bash
set -euo pipefail
source .env

echo "[WARN] Cleaning up API Gateway: $DDN_APIGW_NAME"

# API ID 조회
API_ID=$(aws apigatewayv2 get-apis \
  --query "Items[?Name=='$DDN_APIGW_NAME'].ApiId" \
  --output text)

if [[ -z "$API_ID" ]]; then
  echo "[INFO] API Gateway '$DDN_APIGW_NAME' not found. Nothing to delete."
  exit 0
fi

# API 삭제
aws apigatewayv2 delete-api --api-id $API_ID

aws lambda remove-permission \
  --function-name $DDN_LAMBDA_FUNC_NAME \
  --statement-id apigateway-access

echo "[INFO] API Gateway '$DDN_APIGW_NAME' (ID: $API_ID) deleted."
