#!/usr/bin/env bash
set -euo pipefail
source .env
aws configure set region "$AWS_REGION"

echo "[INFO] Deleting all images in ECR repo: $DDN_ECR_REPO"

# 모든 이미지 삭제 (있으면)
IMAGE_IDS=$(aws ecr list-images \
  --repository-name "$DDN_ECR_REPO" \
  --query 'imageIds[*]' \
  --output json)

if [ "$IMAGE_IDS" != "[]" ]; then
  aws ecr batch-delete-image \
    --repository-name "$DDN_ECR_REPO" \
    --image-ids "$IMAGE_IDS" || true
else
  echo "[INFO] No images found in repo"
fi

# 리포지토리 삭제
aws ecr delete-repository --repository-name "$DDN_ECR_REPO" --force || true
echo "[DONE] ECR repository $DDN_ECR_REPO deleted"
