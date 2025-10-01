#!/usr/bin/env bash
set -euo pipefail
source .env

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
    --api-id $EXISTING_API_ID \
    --query "Items[?IntegrationType=='HTTP_PROXY'].IntegrationId" \
    --output text)

  if [[ -n "$ALB_INTEG_ID" ]]; then
    echo "[INFO] Updating ALB integration ($ALB_INTEG_ID) with new DNS: $DDN_ALB_DNS"
    aws apigatewayv2 update-integration \
      --api-id $EXISTING_API_ID \
      --integration-id $ALB_INTEG_ID \
      --integration-uri "http://$DDN_ALB_DNS" >/dev/null
    echo "[OK] ALB integration updated."
  else
    echo "[WARN] No existing ALB integration found. Creating new one..."
    aws apigatewayv2 create-integration \
      --api-id $EXISTING_API_ID \
      --integration-type HTTP_PROXY \
      --integration-uri "http://$DDN_ALB_DNS" \
      --integration-method ANY \
      --payload-format-version 1.0
  fi

  echo "[INFO] API Gateway endpoint:"
  echo "https://$EXISTING_API_ID.execute-api.$AWS_REGION.amazonaws.com"
  exit 0
fi

echo "[INFO] Creating API Gateway: $DDN_APIGW_NAME"

# 1. Create API
API_ID=$(aws apigatewayv2 create-api \
  --name $DDN_APIGW_NAME \
  --protocol-type HTTP \
  --query 'ApiId' \
  --output text)

echo "[INFO] API Gateway created with ID: $API_ID"

# 2. Lambda integration (presign)
LAMBDA_INTEG_ID=$(aws apigatewayv2 create-integration \
  --api-id $API_ID \
  --integration-type AWS_PROXY \
  --integration-uri arn:aws:lambda:$AWS_REGION:$ACCOUNT_ID:function:$DDN_LAMBDA_FUNC_NAME \
  --payload-format-version 2.0 \
  --query 'IntegrationId' --output text)

# 3. ALB integration (Flask ECS)
ALB_URL="http://$DDN_ALB_DNS"
ALB_INTEG_ID=$(aws apigatewayv2 create-integration \
  --api-id $API_ID \
  --integration-type HTTP_PROXY \
  --integration-uri $ALB_URL \
  --integration-method ANY \
  --payload-format-version 1.0 \
  --query 'IntegrationId' --output text)

# Logging for ALB URL and Integration ID
echo "[INFO] ALB URL: $ALB_URL"
echo "[INFO] ALB Integration ID: $ALB_INTEG_ID"

# 4. Routes
aws apigatewayv2 create-route --api-id $API_ID --route-key "GET /presign" --target integrations/$LAMBDA_INTEG_ID
aws apigatewayv2 create-route --api-id $API_ID --route-key "POST /presign" --target integrations/$LAMBDA_INTEG_ID
aws apigatewayv2 create-route --api-id $API_ID --route-key "GET /ping" --target integrations/$ALB_INTEG_ID
aws apigatewayv2 create-route --api-id $API_ID --route-key "POST /invocations" --target integrations/$ALB_INTEG_ID

echo "[INFO] Routes created."

# 5. Add Lambda permission
aws lambda add-permission \
  --function-name $DDN_LAMBDA_FUNC_NAME \
  --statement-id apigateway-access \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:$AWS_REGION:$ACCOUNT_ID:$API_ID/*/*"

# 6. Deploy
aws apigatewayv2 create-stage \
  --api-id $API_ID \
  --stage-name '$default' \
  --auto-deploy

echo "[INFO] API Gateway deployed to stage: $DDN_APIGW_NAME/\$default"
echo "[INFO] API Gateway endpoint:"
echo "https://$API_ID.execute-api.$AWS_REGION.amazonaws.com"
