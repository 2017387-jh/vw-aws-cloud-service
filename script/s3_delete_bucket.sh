#!/usr/bin/env bash
set -euo pipefail
source .env
aws configure set region "$AWS_REGION"

for b in "$DDN_IN_BUCKET" "$DDN_OUT_BUCKET"; do
  echo "[INFO] Deleting bucket: $b"
  aws s3 rm "s3://$b" --recursive || true
  aws s3 rb "s3://$b" --force || true
done
