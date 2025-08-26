#!/usr/bin/env bash
set -euo pipefail
source .env

INPUT_KEY=${1:-"user/test_input.tif"}
OUTPUT_KEY=${2:-"user/test_output.tif"}
REQUEST_ID="req-$(date +%s)"

echo "[INFO] Submitting async inference request..."
aws sagemaker-runtime invoke-endpoint-async \
  --region $AWS_REGION \
  --endpoint-name $DDN_SM_ENDPOINT \
  --input-location "s3://$DDN_IN_BUCKET/$INPUT_KEY" \
  --content-type "application/octet-stream" \
  --accept "application/octet-stream" \
  --inference-id "$REQUEST_ID" \
  --output-location "s3://$DDN_OUT_BUCKET/$OUTPUT_KEY"

echo "[INFO] Request submitted."
echo "       RequestID: $REQUEST_ID"
echo "       Input:  s3://$DDN_IN_BUCKET/$INPUT_KEY"
echo "       Output: s3://$DDN_OUT_BUCKET/$OUTPUT_KEY"