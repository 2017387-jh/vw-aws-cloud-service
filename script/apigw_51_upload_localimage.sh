#!/usr/bin/env bash
set -euo pipefail

# ===== 설정 =====
API_ENDPOINT="https://z1ylop2ne3.execute-api.ap-northeast-2.amazonaws.com"
LOCAL_FILE="./image/static_demo_140um_madible_VD.tif"
S3_KEY="user/static_demo_140um_madible_VD.tif"

echo "[INFO] Upload test started"
echo "[INFO] Local file: $LOCAL_FILE"
echo "[INFO] Target S3 key: $S3_KEY"

# 1. Lambda 호출 → presigned URL 요청
echo "[INFO] Requesting presigned URL from API Gateway..."
UPLOAD_URL=$(curl -s "${API_ENDPOINT}?mode=upload&file=${S3_KEY}" | jq -r '.url')

if [[ "$UPLOAD_URL" == "null" || -z "$UPLOAD_URL" ]]; then
  echo "[ERROR] Failed to get presigned URL"
  exit 1
fi

echo "[INFO] Presigned URL acquired:"
echo "$UPLOAD_URL"

# 2. 로컬 파일 업로드 → S3
echo "[INFO] Uploading file to S3..."
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X PUT --upload-file "$LOCAL_FILE" "$UPLOAD_URL")

if [[ "$STATUS" != "200" ]]; then
  echo "[ERROR] Upload failed with HTTP status: $STATUS"
  exit 1
fi

echo "[INFO] Upload finished successfully (HTTP $STATUS)"
echo "[INFO] File [$LOCAL_FILE] is now stored in [$S3_KEY] at S3 bucket (via presigned URL)"
