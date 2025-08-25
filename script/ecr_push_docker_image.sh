#!/usr/bin/env bash
set -euo pipefail
source .env

START_TIME=$(date +%s)   # Start time

# ===== Docker login =====
echo "[INFO] Logging in to ECR..."
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"

# ===== Image URI =====
IMAGE_URI_BASE="$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$VW_ECR_REPO"
IMAGE_URI_TAG="$IMAGE_URI_BASE:$VW_ECR_TAG"
IMAGE_URI_LATEST="$IMAGE_URI_BASE:latest"

# ===== Source Image (local) =====
if docker image inspect "$VW_LOCAL_IMAGE:$VW_ECR_TAG" >/dev/null 2>&1; then
  SRC_REF="$VW_LOCAL_IMAGE:$VW_ECR_TAG"
else
  # Recent Image
  SRC_REF=$(docker images -q | head -n1)
  if [ -z "$SRC_REF" ]; then
    echo "[ERROR] No image found after docker load"
    exit 1
  fi
fi

# ===== Tagging =====
echo "[INFO] Tagging $SRC_REF -> $IMAGE_URI_TAG and :latest"
docker tag "$SRC_REF" "$IMAGE_URI_TAG"
docker tag "$SRC_REF" "$IMAGE_URI_LATEST"

# ===== Pushing =====
echo "[INFO] Pushing $IMAGE_URI_TAG"
docker push "$IMAGE_URI_TAG"

echo "[INFO] Pushing $IMAGE_URI_LATEST"
docker push "$IMAGE_URI_LATEST"

END_TIME=$(date +%s)   # End time
ELAPSED=$(( END_TIME - START_TIME ))

echo "[DONE] Pushed to ECR: $IMAGE_URI_TAG and $IMAGE_URI_LATEST"
echo "[TIME] Total elapsed time: ${ELAPSED} seconds"
