#!/usr/bin/env bash
set -euo pipefail
source .env
aws configure set region "$AWS_REGION"

FILE_PATH=${1:-test_input.tif}
S3_KEY=${2:-user/test_input.tif}

echo "[INFO] Uploading $FILE_PATH to s3://$DDN_IN_BUCKET/$S3_KEY"
aws s3 cp "$FILE_PATH" "s3://$DDN_IN_BUCKET/$S3_KEY"
