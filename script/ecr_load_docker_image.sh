#!/bin/bash
set -euo pipefail
source .env

# ===== Check tar file exists =====
if [ ! -f "$VW_ECR_TAR" ]; then
  echo "[ERROR] TAR file not found: $VW_ECR_TAR"
  exit 1
fi

echo "[INFO] Loading docker image from $VW_ECR_TAR"
docker load -i "$VW_ECR_TAR"
echo "[DONE] Image loaded locally."