#!/usr/bin/env bash
set -euo pipefail
source .env

echo "[INFO] Testing Lambda function: $DDN_LAMBDA_FUNC_NAME (download)"
echo "[INFO] Target S3 key: $DDN_TEST_IMAGE_KEY"

# 1. Request Presigned
echo "[INFO] Requesting presigned URL for download..."
aws lambda invoke \
  --function-name $DDN_LAMBDA_FUNC_NAME \
  --payload "{\"queryStringParameters\":{\"mode\":\"download\",\"file\":\"$IMAGE_KEY="user/static_demo_140um_madible_VD.tif"
\"}}" \
  download_response.json \
  --region $AWS_REGION \
  --cli-binary-format raw-in-base64-out >/dev/null

DOWNLOAD_URL=$(jq -r '.url' download_response.json)
echo "[INFO] Download URL: $DOWNLOAD_URL"

# 2. Download
echo "[INFO] Downloading file from S3 via presigned URL..."
STATUS=$(curl -s -o downloaded_test.tif -w "%{http_code}" "$DOWNLOAD_URL")
echo "[INFO] Download finished with HTTP status: $STATUS"
echo "[INFO] File saved as downloaded_test.tif"
