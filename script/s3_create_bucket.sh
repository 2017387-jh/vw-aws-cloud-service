#!/usr/bin/env bash
set -euo pipefail
source .env
aws configure set region "$AWS_REGION"

for b in "$DDN_IN_BUCKET" "$DDN_OUT_BUCKET"; do
  echo "[INFO] Creating bucket: $b"
  aws s3api create-bucket \
    --bucket "$b" \
    --create-bucket-configuration LocationConstraint="$AWS_REGION" || true

  # 퍼블릭 접근 차단 설정
  #   - BlockPublicAcls: 퍼블릭 ACL 업로드/적용 차단
  #   - IgnorePublicAcls: 이미 퍼블릭 ACL이 있더라도 무시
  #   - BlockPublicPolicy: 퍼블릭 접근 허용하는 Bucket Policy 차단
  #   - RestrictPublicBuckets: 계정 레벨에서 퍼블릭 정책 적용 금지
  aws s3api put-public-access-block --bucket "$b" \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

  # 버킷 버전 관리 설정
  #   - S3에 업로드되는 객체(파일)에 대해 버전 관리 기능 활성화
  aws s3api put-bucket-versioning --bucket "$b" \
    --versioning-configuration Status=Enabled
done
