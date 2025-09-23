import os
import json
import time
import boto3
import requests
from dotenv import load_dotenv

# .env 파일 로드
load_dotenv()

# 환경 변수 가져오기
lambda_name = os.getenv("DDN_LAMBDA_FUNC_NAME")
image_path = os.getenv("DDN_TEST_IMAGE_PATH")   # 다운로드 받을 로컬 경로
image_key = os.getenv("DDN_TEST_IMAGE_KEY")
region = os.getenv("AWS_REGION")
out_bucket = os.getenv("DDN_OUT_BUCKET")

print(f"[INFO] Testing Lambda function: {lambda_name} (download)")
print(f"[INFO] Save path: {image_path}")
print(f"[INFO] Target S3 key: {image_key}")

# boto3 클라이언트 준비
lambda_client = boto3.client("lambda", region_name=region)

# 1. Presigned URL 요청 (Lambda invoke, download 모드)
print("[INFO] Requesting presigned URL for download...")
payload = {
    "queryStringParameters": {
        "mode": "download",
        "file": image_key
    }
}
response = lambda_client.invoke(
    FunctionName=lambda_name,
    Payload=json.dumps(payload).encode("utf-8")
)
resp_payload = json.loads(response["Payload"].read())
print("[INFO] Lambda response:", resp_payload)

# Download URL 추출
download_url = json.loads(resp_payload["body"])["url"]
print("[INFO] Download URL:", download_url)

# 2. Presigned URL 다운로드
print("[INFO] Downloading image from S3 via presigned URL...")
start_time = time.perf_counter()
r = requests.get(download_url, stream=True)
end_time = time.perf_counter()

if r.status_code == 200:
    with open(image_path, "wb") as f:
        for chunk in r.iter_content(chunk_size=8192):
            if chunk:
                f.write(chunk)
    print(f"[INFO] Download finished successfully: {image_path}")
else:
    print(f"[ERROR] Download failed with HTTP status: {r.status_code}")

# 다운로드 시간(ms) 계산 및 출력
elapsed_ms = (end_time - start_time) * 1000
print(f"[INFO] Download time: {elapsed_ms:.2f} ms")

print("[INFO] Test finished.")
