#!/usr/bin/env bash
set -euo pipefail
source .env
aws configure set region "$AWS_REGION"

# 버킷 생성
aws s3api create-bucket --bucket "$SRC_BUCKET" --create-bucket-configuration LocationConstraint="$AWS_REGION" || true
aws s3api create-bucket --bucket "$OUT_BUCKET" --create-bucket-configuration LocationConstraint="$AWS_REGION" || true

# 퍼블릭 차단 + 버전닝
for b in "$SRC_BUCKET" "$OUT_BUCKET"; do
  aws s3api put-public-access-block --bucket "$b" \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-versioning --bucket "$b" --versioning-configuration Status=Enabled
done

# 샘플 파일 업/다운 (텍스트 파일 생성)
echo "1" > sample.txt

aws s3 cp sample.txt "s3://$SRC_BUCKET/raw/sample.txt"
aws s3 cp "s3://$SRC_BUCKET/raw/sample.txt" ./download.txt

# Presigned URL 예시(GET/PUT)
echo "GET URL:"
aws s3 presign "s3://$SRC_BUCKET/raw/sample.txt" --expires-in 600

echo "PUT URL:"
aws s3 presign "s3://$SRC_BUCKET/raw/new.txt" --expires-in 600 --http-method PUT
