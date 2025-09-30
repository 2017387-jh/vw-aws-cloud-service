import subprocess
import json
import time
import os
import requests
from dotenv import load_dotenv
from pathlib import Path

# .env 파일 로드
load_dotenv()

# 환경 변수 로드
lambda_name = os.getenv("DDN_LAMBDA_FUNC_NAME")
image_path = os.getenv("DDN_TEST_IMAGE_PATH")
image_key = os.getenv("DDN_TEST_IMAGE_KEY")
region = os.getenv("AWS_REGION")
in_bucket = os.getenv("DDN_IN_BUCKET")
out_bucket = os.getenv("DDN_OUT_BUCKET")

# print 환경 변수 확인
print("[INFO] Lambda Function Name:", lambda_name)
print("[INFO] Test Image Path:", image_path)
print("[INFO] Test Image Key:", image_key)
print("[INFO] AWS Region:", region)
print("[INFO] IN Bucket:", in_bucket)
print("[INFO] OUT Bucket:", out_bucket)
print("[INFO] AWS Region:", region)

start_time = time.perf_counter()

# Lambda 호출 (여기는 그대로 CLI 사용)
cmd = [
    "aws", "lambda", "invoke",
    "--function-name", lambda_name,
    "--payload", f'{{"queryStringParameters":{{"mode":"upload","file":"{image_key}"}}}}',
    "upload_response.json",
    "--region", region,
    "--cli-binary-format", "raw-in-base64-out"
]
subprocess.run(cmd, check=True)

# 결과 읽기
with open("upload_response.json") as f:
    resp = json.load(f)
upload_url = json.loads(resp["body"])["url"]
print("[INFO] Upload URL:", upload_url)

# requests 로 업로드
print("[INFO] Uploading image via presigned URL...")
abs_image_path = Path(image_path).resolve()  # 절대경로 변환
with open(abs_image_path, "rb") as f:
    r = requests.put(upload_url, data=f)

end_time = time.perf_counter()

print("[INFO] Upload finished with HTTP status:", r.status_code)

# 업로드 시간(ms) 계산 및 출력
elapsed_ms = (end_time - start_time) * 1000
print(f"[INFO] Upload time: {elapsed_ms:.2f} ms")

# s3 copy (CLI 그대로 사용)
subprocess.run([
    "aws", "s3", "cp",
    f"s3://{in_bucket}/{image_key}",
    f"s3://{out_bucket}/{image_key}",
    "--region", region
], check=True)

print("[INFO] Test finished.")
