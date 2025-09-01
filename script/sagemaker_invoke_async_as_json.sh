#!/usr/bin/env bash
set -euo pipefail
source .env

# 입력값
INPUT_KEY=${1:-"user/test_input.tif"}     # S3 입력 경로 (버킷 내부 Key)
OUTPUT_KEY=${2:-"user/test_output.json"}  # S3 출력 경로 (버킷 내부 Key)
REQUEST_ID="req-$(date +%s)"              # 요청 추적용 ID

echo "[INFO] Submitting async inference request..."
# aws sagemaker-runtime invoke-endpoint-async \
#   --region $AWS_REGION \
#   --endpoint-name $DDN_SM_ENDPOINT \
#   --input-location "s3://$DDN_IN_BUCKET/$INPUT_KEY" \
#   --content-type "application/octet-stream" \
#   --accept "application/json" \
#   --inference-id "$REQUEST_ID" \
#   --output-location "s3://$DDN_OUT_BUCKET/$OUTPUT_KEY"

aws sagemaker-runtime invoke-endpoint-async \
  --region "$AWS_REGION" \
  --endpoint-name "$DDN_SM_ENDPOINT" \
  --input-location "s3://$DDN_IN_BUCKET/user/test_input.tif" \
  --content-type image/tiff

echo "[INFO] Request submitted."
echo "       RequestID: $REQUEST_ID"
echo "       Input:  s3://$DDN_IN_BUCKET/$INPUT_KEY"
echo "       Output: s3://$DDN_OUT_BUCKET/$OUTPUT_KEY"