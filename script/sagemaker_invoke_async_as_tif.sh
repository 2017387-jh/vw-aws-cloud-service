#!/usr/bin/env bash
set -euo pipefail
source .env

INPUT_KEY=${1:-"user/test_input.tif"}
REQUEST_ID="req-$(date +%s)"

IN_S3="s3://${DDN_IN_BUCKET}/${INPUT_KEY}"

echo "[INFO] Endpoint     : ${DDN_SM_ENDPOINT}"
echo "[INFO] Input (S3)   : ${IN_S3}"
echo "[INFO] Output base  : ${DDN_ASYNC_S3_OUTPUT}"
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

INFERENCE_ID=$(echo "$resp_json" | sed -E 's/.*"InferenceId"\s*:\s*"([^"]+)".*/\1/')
OUTPUT_LOCATION=$(echo "$resp_json" | sed -E 's/.*"OutputLocation"\s*:\s*"([^"]+)".*/\1/')

echo "[INFO] Request submitted."
echo "       InferenceId    : $INFERENCE_ID"
echo "       OutputLocation : $OUTPUT_LOCATION"

cat <<'TIP'
[HINT] 결과가 준비되면 OutputLocation(S3 경로)에 JSON/이미지가 생성됩니다.
  aws s3 ls s3://ddn-out-bucket/user/
  aws s3 cp  <OutputLocation> ./output.json
TIP
