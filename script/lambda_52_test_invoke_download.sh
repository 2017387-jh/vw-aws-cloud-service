#!/usr/bin/env bash
set -euo pipefail
source .env

echo "[INFO] Testing Lambda function: $DDN_LAMBDA_FUNC_NAME (download)"
echo "[INFO] Target S3 key: $DDN_TEST_IMAGE_KEY"

# 1. Request Presigned (파이프 방식, 임시파일 없음)
DOWNLOAD_URL=$(
  aws lambda invoke \
    --function-name $DDN_LAMBDA_FUNC_NAME \
    --payload "{\"queryStringParameters\":{\"mode\":\"download\",\"file\":\"$DDN_TEST_IMAGE_KEY\"}}" \
    --region $AWS_REGION \
    --cli-binary-format raw-in-base64-out \
    /dev/stdout \
    --query 'body' --output text | jq -r '.url'
)

echo "[INFO] Download URL: $DOWNLOAD_URL"

# 2. Download
echo "[INFO] Downloading file from S3 via presigned URL..."
STATUS=$(curl -s -S -f -o downloaded_test.tif -w "%{http_code}" "$DOWNLOAD_URL") || {
    echo "[ERROR] curl failed while downloading file"
    exit 1
}

echo "[INFO] Download finished with HTTP status: $STATUS"
echo "[INFO] File saved as downloaded_test.tif"