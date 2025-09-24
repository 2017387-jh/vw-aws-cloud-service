import os
import sys
import time
import requests
from pathlib import Path
from dotenv import load_dotenv

# .env 파일 로드
load_dotenv()

# ===== 설정 =====
API_ENDPOINT = os.getenv("DDN_TEST_API_ENDPOINT")  # .env 안에 API Gateway 엔드포인트 넣으시면 됩니다
LOCAL_FILE = os.getenv("DDN_TEST_IMAGE_PATH")   # 로컬 파일 경로
S3_KEY = os.getenv("DDN_TEST_IMAGE_KEY")        # S3 Key

print("[INFO] Upload test started")
print(f"[INFO] Local file: {LOCAL_FILE}")
print(f"[INFO] Target S3 key: {S3_KEY}")

start_time = time.perf_counter()

# 1. Lambda 호출 → presigned URL 요청
print("[INFO] Requesting presigned URL from API Gateway...")
try:
    resp = requests.get(f"{API_ENDPOINT}?mode=upload&file={S3_KEY}")
    resp.raise_for_status()
    upload_url = resp.json().get("url")
except Exception as e:
    print(f"[ERROR] Failed to get presigned URL: {e}")
    sys.exit(1)

if not upload_url:
    print("[ERROR] Presigned URL not found in response")
    sys.exit(1)

print("[INFO] Presigned URL acquired:")
print(upload_url)

# 2. 로컬 파일 업로드 → S3
print("[INFO] Uploading file to S3...")
file_path = Path(LOCAL_FILE).resolve()
if not file_path.exists():
    print(f"[ERROR] Local file not found: {file_path}")
    sys.exit(1)

with open(file_path, "rb") as f:
    r = requests.put(upload_url, data=f)

if r.status_code != 200:
    print(f"[ERROR] Upload failed with HTTP status: {r.status_code}")
    sys.exit(1)

end_time = time.perf_counter()
elapsed_ms = (end_time - start_time) * 1000

print(f"[INFO] Upload finished successfully (HTTP {r.status_code})")
print(f"[INFO] Upload time: {elapsed_ms:.2f} ms")
print(f"[INFO] File [{file_path}] is now stored in [{S3_KEY}] at S3 bucket (via presigned URL)")
