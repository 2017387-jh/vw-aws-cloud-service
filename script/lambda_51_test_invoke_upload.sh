#!/usr/bin/env bash
set -euo pipefail
source .env

echo "[INFO] Testing Lambda function: $DDN_LAMBDA_FUNC_NAME (upload)"
echo "[INFO] Using image: $DDN_TEST_IMAGE_PATH"
echo "[INFO] Target S3 key: $DDN_TEST_IMAGE_KEY"

# 1. Request Presigned URL
echo "[INFO] Requesting presigned URL for upload..."
aws lambda invoke \
  --function-name $DDN_LAMBDA_FUNC_NAME \
  --payload "{\"queryStringParameters\":{\"mode\":\"upload\",\"file\":\"$DDN_TEST_IMAGE_KEY\"}}" \
  upload_response.json \
  --region $AWS_REGION \
  --cli-binary-format raw-in-base64-out >/dev/null

# echo upload_response.json
cat upload_response.json

# Parse Upload URL
UPLOAD_URL=$(jq -r '.body' upload_response.json | jq -r '.url')
echo "[INFO] Upload URL: $UPLOAD_URL"

# 2. Upload Image
echo "[INFO] Uploading image to S3 via presigned URL..."
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X PUT --upload-file "$DDN_TEST_IMAGE_PATH" "$UPLOAD_URL")
echo "[INFO] Upload finished with HTTP status: $STATUS"

# Test-only: copy from IN bucket to OUT bucket
echo "[INFO] Copying uploaded file from $DDN_IN_BUCKET to $DDN_OUT_BUCKET (test only)"
aws s3 cp \
  s3://$DDN_IN_BUCKET/$DDN_TEST_IMAGE_KEY \
  s3://$DDN_OUT_BUCKET/$DDN_TEST_IMAGE_KEY \
  --region $AWS_REGION

rm -f upload_response.json
echo "[INFO] Test finished."