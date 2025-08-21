#!/usr/bin/env bash
set -euo pipefail
source .env
aws configure set region "$AWS_REGION"

for b in "$VW_IMG_SRC_BUCKET" "$VW_IMG_OUT_BUCKET"; do
  echo "[INFO] Creating bucket: $b"
  aws s3api create-bucket \
    --bucket "$b" \
    --create-bucket-configuration LocationConstraint="$AWS_REGION" || true

  aws s3api put-public-access-block --bucket "$b" \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

  aws s3api put-bucket-versioning --bucket "$b" \
    --versioning-configuration Status=Enabled
done
