#!/bin/bash
set -euo pipefail
source .env

# ===== Check tar file exists =====
if [ ! -f "$DDN_ECR_IMG_TAR" ]; then
  echo "[ERROR] TAR file not found: $DDN_ECR_IMG_TAR"
  exit 1
fi

echo "[INFO] Loading docker image from $DDN_ECR_IMG_TAR"
docker load -i "$DDN_ECR_IMG_TAR"
echo "[DONE] Image loaded locally."