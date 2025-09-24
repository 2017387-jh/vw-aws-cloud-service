#!/usr/bin/env bash
set -euo pipefail
source .env

echo "[WARN] Cleaning up all API Gateway instances named: $DDN_APIGW_NAME"

# API ID 목록 조회 (여러 개 가능)
API_IDS=$(aws apigatewayv2 get-apis \
  --query "Items[?Name=='$DDN_APIGW_NAME'].ApiId" \
  --output text)

if [[ -z "$API_IDS" ]]; then
  echo "[INFO] API Gateway '$DDN_APIGW_NAME' not found. Nothing to delete."
  exit 0
fi

for API_ID in $API_IDS; do
  echo "[INFO] Deleting API Gateway '$DDN_APIGW_NAME' (ID: $API_ID)..."
  aws apigatewayv2 delete-api --api-id "$API_ID"
done

# Lambda permission 삭제 (중복 호출 시도해도 문제 없음)
set +e
aws lambda remove-permission \
  --function-name "$DDN_LAMBDA_FUNC_NAME" \
  --statement-id apigateway-access
set -e

echo "[INFO] All API Gateways named '$DDN_APIGW_NAME' deleted."
echo "[INFO] Cleanup completed."