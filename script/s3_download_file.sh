#!/usr/bin/env bash
set -euo pipefail
source .env
aws configure set region "$AWS_REGION"

S3_KEY=${1:-raw/sample.txt}
LOCAL_PATH=${2:-download.txt}

echo "[INFO] Downloading s3://$DDN_IN_BUCKET/$S3_KEY to $LOCAL_PATH"
aws s3 cp "s3://$DDN_IN_BUCKET/$S3_KEY" "$LOCAL_PATH"
