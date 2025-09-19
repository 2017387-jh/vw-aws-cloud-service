#!/usr/bin/env bash
set -euo pipefail
source .env

echo "[WARN] Cleaning up Lambda resources..."
echo "       Function: $DDN_LAMBDA_FUNC_NAME"
echo "       Role:     $DDN_LAMBDA_ROLE"

# 1. Lambda 함수 삭제
aws lambda delete-function \
  --function-name $DDN_LAMBDA_FUNC_NAME \
  --region $AWS_REGION || true

# 2. IAM 정책 분리
aws iam detach-role-policy \
  --role-name $DDN_LAMBDA_ROLE \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess || true

# 3. IAM Role 삭제
aws iam delete-role \
  --role-name $DDN_LAMBDA_ROLE || true

echo "[INFO] Lambda cleanup finished."