#!/usr/bin/env bash
set -euo pipefail
source .env

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
