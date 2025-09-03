#!/usr/bin/env bash
set -euo pipefail
source .env

# 사용법:
#   ./invoke_async.sh [INPUT_KEY]
# 예: 
#   ./invoke_async.sh user/test_input.tif

INPUT_KEY=${1:-"user/test_input.tif"}
REQUEST_ID="req-$(date +%s)"

IN_S3="s3://${DDN_IN_BUCKET}/${INPUT_KEY}"

echo "[INFO] Submitting async inference request..."
resp_json=$(
  aws sagemaker-runtime invoke-endpoint-async \
    --region "$AWS_REGION" \
    --endpoint-name "$DDN_SM_ENDPOINT" \
    --input-location "$IN_S3" \
    --content-type "image/tiff" \
    --inference-id "$REQUEST_ID" \
    --query '{InferenceId:InferenceId,OutputLocation:OutputLocation}' \
    --output json
)

# 간단 파싱
INFERENCE_ID=$(echo "$resp_json" | sed -E 's/.*"InferenceId"\s*:\s*"([^"]+)".*/\1/')
OUTPUT_LOCATION=$(echo "$resp_json" | sed -E 's/.*"OutputLocation"\s*:\s*"([^"]+)".*/\1/')

echo "[INFO] Request submitted."
echo "       RequestID      : $INFERENCE_ID"
echo "       Input (S3)     : $IN_S3"
echo "       OutputLocation : $OUTPUT_LOCATION"
echo
echo "[HINT] 결과 객체가 생성되면 위 OutputLocation(S3 경로)로 다운로드하세요."
echo "       aws s3 cp \"$OUTPUT_LOCATION\" ./output.json"
