#!/usr/bin/env bash
set -euo pipefail

# Load .env
source .env

echo "[INFO] Creating SageMaker Model: $DDN_MODEL_NAME"

aws sagemaker create-model \
  --region $AWS_REGION \
  --model-name $DDN_MODEL_NAME \
  --primary-container "Image=$DDN_IMAGE_URI,ContainerEntrypoint=[\"sh\",\"-c\"],ContainerArguments=[\"tritonserver --model-repository=/models & python3 /opt/program/inference_handler.py & wait\"]" \
  --execution-role-arn $DDN_EXEC_ROLE_ARN