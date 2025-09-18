#!/usr/bin/env bash
set -euo pipefail
source .env

echo "[INFO] Packaging Lambda function"
rm -f ddn_lambda_function.zip
zip ddn_lambda_function.zip lambda_function.py

echo "[INFO] Creating Lambda function: $DDN_LAMBDA_FUNC_NAME"
aws lambda create-function \
  --function-name $DDN_LAMBDA_FUNC_NAME \
  --runtime python3.12 \
  --role arn:aws:iam::$ACCOUNT_ID:role/$DDN_LAMBDA_ROLE \
  --handler lambda_function.lambda_handler \
  --zip-file fileb://ddn_lambda_function.zip \
  --environment "Variables={AWS_REGION=$AWS_REGION,DDN_IN_BUCKET=$DDN_IN_BUCKET,DDN_OUT_BUCKET=$DDN_OUT_BUCKET}"
