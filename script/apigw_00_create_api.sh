#!/usr/bin/env bash
set -euo pipefail
source .env

echo "[INFO] Creating API Gateway: $DDN_APIGW_NAME"

# Create API Gateway (HTTP API v2)
API_ID=$(aws apigatewayv2 create-api \
  --name $DDN_APIGW_NAME \
  --protocol-type HTTP \
  --target arn:aws:lambda:$AWS_REGION:$ACCOUNT_ID:function:$DDN_LAMBDA_FUNC_NAME \
  --query 'ApiId' \
  --output text)

echo "[INFO] API Gateway created with ID: $API_ID"

# Add Lambda permission for API Gateway
aws lambda add-permission \
  --function-name $DDN_LAMBDA_FUNC_NAME \
  --statement-id apigateway-access \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:$AWS_REGION:$ACCOUNT_ID:$API_ID/*/*"

echo "[INFO] API Gateway endpoint:"
echo "https://$API_ID.execute-api.$AWS_REGION.amazonaws.com"
