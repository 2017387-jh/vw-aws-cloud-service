#!/usr/bin/env bash
set -euo pipefail
source .env

DDN_MAX_CONCURRENCY=2         # 선택
DDN_INVOCATION_TIMEOUT=3600   # 선택(최대 3600)

echo "[INFO] Checking if Endpoint Config '$DDN_ENDPOINT_CONFIG' already exists..."
if aws sagemaker describe-endpoint-config \
    --region "$AWS_REGION" \
    --endpoint-config-name "$DDN_ENDPOINT_CONFIG" >/dev/null 2>&1; then
  echo "[WARN] Endpoint Config '$DDN_ENDPOINT_CONFIG' already exists. Deleting..."
  aws sagemaker delete-endpoint-config \
    --region "$AWS_REGION" \
    --endpoint-config-name "$DDN_ENDPOINT_CONFIG"
  echo "[INFO] Deleted existing Endpoint Config: $DDN_ENDPOINT_CONFIG"
fi

# Async Inference 설정 JSON 구성
ASYNC_JSON=$(cat <<JSON
{
  "ClientConfig": {
    "MaxConcurrentInvocationsPerInstance": ${DDN_MAX_CONCURRENCY}
  },
  "OutputConfig": {
    "S3OutputPath": "${DDN_ASYNC_S3_OUTPUT}"
  }
}
JSON
)

echo "[INFO] Creating ASYNC Endpoint Config: $DDN_ENDPOINT_CONFIG"
aws sagemaker create-endpoint-config \
  --region "$AWS_REGION" \
  --endpoint-config-name "$DDN_ENDPOINT_CONFIG" \
  --production-variants VariantName=AllTraffic,ModelName=$DDN_MODEL_NAME,InitialInstanceCount=${DDN_SM_INITIAL_INSTANCE_COUNT},InstanceType=${DDN_SM_INSTANCE_TYPE} \
  --async-inference-config "${ASYNC_JSON}"

# 엔드포인트가 이미 있으면 업데이트, 없으면 생성
if aws sagemaker describe-endpoint \
    --region "$AWS_REGION" \
    --endpoint-name "$DDN_SM_ENDPOINT" >/dev/null 2>&1; then
  echo "[INFO] Updating Endpoint: $DDN_SM_ENDPOINT"
  aws sagemaker update-endpoint \
    --region "$AWS_REGION" \
    --endpoint-name "$DDN_SM_ENDPOINT" \
    --endpoint-config-name "$DDN_ENDPOINT_CONFIG"
else
  echo "[INFO] Creating Endpoint: $DDN_SM_ENDPOINT"
  aws sagemaker create-endpoint \
    --region "$AWS_REGION" \
    --endpoint-name "$DDN_SM_ENDPOINT" \
    --endpoint-config-name "$DDN_ENDPOINT_CONFIG"
fi

echo "[INFO] Endpoint creation submitted. Use the following command to check status:"
echo "aws sagemaker describe-endpoint --region $AWS_REGION --endpoint-name $DDN_SM_ENDPOINT --query 'EndpointStatus'"
