#!/usr/bin/env bash
set -euo pipefail

# =========================
# Config & Preconditions
# =========================
source .env

: "${AWS_REGION:?AWS_REGION required}"
: "${ACCOUNT_ID:?ACCOUNT_ID required}"
: "${DDN_LAMBDA_FUNC_NAME:?DDN_LAMBDA_FUNC_NAME required}"
: "${DDN_LAMBDA_ROLE:?DDN_LAMBDA_ROLE required}"
: "${DDN_IN_BUCKET:?DDN_IN_BUCKET required}"
: "${DDN_OUT_BUCKET:?DDN_OUT_BUCKET required}"

# 가속/만료시간 기본값 (없으면 기본값 주입)
: "${DDN_USE_S3_ACCELERATE:=false}"
: "${DDN_S3_PRESIGN_EXPIRES:=900}"

aws configure set region "$AWS_REGION"

FUNC_ZIP_FILE="ddn_lambda_function.zip"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${DDN_LAMBDA_ROLE}"

echo "[INFO] Packaging Lambda function"
rm -f "$FUNC_ZIP_FILE"
zip -q "$FUNC_ZIP_FILE" lambda_function.py

# =========================
# Helpers
# =========================
function func_exists() {
  set +e
  aws lambda get-function --function-name "$DDN_LAMBDA_FUNC_NAME" >/dev/null 2>&1
  local rc=$?
  set -e
  return $rc
}

function wait_active() {
  echo "[INFO] Waiting for Lambda to be active: $DDN_LAMBDA_FUNC_NAME"
  aws lambda wait function-active --function-name "$DDN_LAMBDA_FUNC_NAME"
}

function wait_updated() {
  echo "[INFO] Waiting for Lambda to be updated: $DDN_LAMBDA_FUNC_NAME"
  aws lambda wait function-updated --function-name "$DDN_LAMBDA_FUNC_NAME"
}

ENV_VARS="Variables={DDN_IN_BUCKET=$DDN_IN_BUCKET,DDN_OUT_BUCKET=$DDN_OUT_BUCKET,DDN_USE_S3_ACCELERATE=$DDN_USE_S3_ACCELERATE,DDN_S3_PRESIGN_EXPIRES=$DDN_S3_PRESIGN_EXPIRES}"

# =========================
# Create or Update
# =========================
if func_exists; then
  echo "[INFO] Lambda exists. Updating code & configuration: $DDN_LAMBDA_FUNC_NAME"

  # 코드 업데이트
  aws lambda update-function-code \
    --function-name "$DDN_LAMBDA_FUNC_NAME" \
    --zip-file "fileb://$FUNC_ZIP_FILE" >/dev/null

  wait_updated

  # 환경변수 업데이트 (필요 시 타임아웃/메모리 등도 여기서 함께 갱신 가능)
  aws lambda update-function-configuration \
    --function-name "$DDN_LAMBDA_FUNC_NAME" \
    --environment "$ENV_VARS" >/dev/null

  wait_updated
else
  echo "[INFO] Creating Lambda function: $DDN_LAMBDA_FUNC_NAME"
  # 역할 전파 지연 대비 간단 재시도
  for i in {1..5}; do
    if aws iam get-role --role-name "$DDN_LAMBDA_ROLE" >/dev/null 2>&1; then
      break
    fi
    echo "  - Waiting for IAM role to propagate... ($i/5)"
    sleep 3
  done

  aws lambda create-function \
    --function-name "$DDN_LAMBDA_FUNC_NAME" \
    --runtime python3.12 \
    --role "$ROLE_ARN" \
    --handler lambda_function.lambda_handler \
    --zip-file "fileb://$FUNC_ZIP_FILE" \
    --environment "$ENV_VARS" >/dev/null

  wait_active
fi

# =========================
# Show Result
# =========================
echo "[INFO] Deployed. Current configuration:"
aws lambda get-function-configuration \
  --function-name "$DDN_LAMBDA_FUNC_NAME" \
  --query '{FunctionName:FunctionName, LastModified:LastModified, Runtime:Runtime, Role:Role, Timeout:Timeout, MemorySize:MemorySize, Env:Environment.Variables}'
