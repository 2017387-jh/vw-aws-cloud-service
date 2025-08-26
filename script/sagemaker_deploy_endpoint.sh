#!/usr/bin/env bash
set -euo pipefail
source .env

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

echo "[INFO] Creating Endpoint Config: $DDN_ENDPOINT_CONFIG"
aws sagemaker create-endpoint-config \
  --region "$AWS_REGION" \
  --endpoint-config-name "$DDN_ENDPOINT_CONFIG" \
  --production-variants VariantName=AllTraffic,ModelName=$DDN_MODEL_NAME,InitialInstanceCount=1,InstanceType=ml.g4dn.xlarge

echo "[INFO] Creating Endpoint: $DDN_SM_ENDPOINT"
aws sagemaker create-endpoint \
  --region "$AWS_REGION" \
  --endpoint-name "$DDN_SM_ENDPOINT" \
  --endpoint-config-name "$DDN_ENDPOINT_CONFIG"

echo "[INFO] Endpoint creation submitted. Use the following command to check status:"
echo "aws sagemaker describe-endpoint --region $AWS_REGION --endpoint-name $DDN_SM_ENDPOINT --query 'EndpointStatus'"
