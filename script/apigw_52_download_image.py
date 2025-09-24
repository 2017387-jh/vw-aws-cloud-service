import os
import sys
import time
import requests
from pathlib import Path
from dotenv import load_dotenv

# .env 파일 로드
load_dotenv()

# ===== 설정 =====
API_ENDPOINT = os.getenv("DDN_TEST_API_ENDPOINT")  # API Gateway 엔드포인트
LOCAL_FILE = os.getenv("DDN_TEST_IMAGE_PATH")      # 다운로드 받을 로컬 저장 경로
S3_KEY = os.getenv("DDN_TEST_IMAGE_KEY")           # 다운로드할 S3 Key

print("[INFO] Download test started")
print(f"[INFO] Save to local file: {LOCAL_FILE}")
print(f"[INFO] Target S3 key: {S3_KEY}")

start_time = time.perf_counter()

# 1. Lambda 호출 → presigned URL 요청 (download 모드)
print("[INFO] Requesting presigned URL for download from API Gateway...")
try:
    resp = requests.get(f"{API_ENDPOINT}?mode=download&file={S3_KEY}")
    resp.raise_for_status()
    download_url = resp.json().get("url")
except Exception as e:
    print(f"[ERROR] Failed to get presigned URL: {e}")
    sys.exit(1)

if not download_url:
    print("[ERROR] Presigned URL not found in response")
    sys.exit(1)

print("[INFO] Presigned URL acquired:")
print(download_url)

# 2. Presigned URL로 다운로드
print("[INFO] Downloading file from S3 via presigned URL...")
file_path = Path(LOCAL_FILE).resolve()

r = requests.get(download_url, stream=True)
end_time = time.perf_counter()

if r.status_code == 200:
    with open(file_path, "wb") as f:
        for chunk in r.iter_content(chunk_size=8192):
            if chunk:
                f.write(chunk)
    elapsed_ms = (end_time - start_time) * 1000
    print(f"[INFO] Download finished successfully: {file_path}")
    print(f"[INFO] Download time: {elapsed_ms:.2f} ms")
else:
    print(f"[ERROR] Download failed with HTTP status: {r.status_code}")
    sys.exit(1)
