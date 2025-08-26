#!/usr/bin/env bash
set -euo pipefail
source .env
aws configure set region "$AWS_REGION"

echo "1" > sample.txt

FILE_PATH=${1:-sample.txt}
S3_KEY=${2:-raw/sample.txt}

echo "[INFO] Uploading $FILE_PATH to s3://$DDN_IN_BUCKET/$S3_KEY"
aws s3 cp "$FILE_PATH" "s3://$DDN_IN_BUCKET/$S3_KEY"
