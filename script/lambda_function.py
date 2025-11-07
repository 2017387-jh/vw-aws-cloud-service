import boto3
import json
import os
import urllib.parse
from botocore.config import Config

ACCELERATE = os.environ.get("DDN_S3_USE_ACCELERATE", "false").lower() == "true"
EXPIRES = int(os.environ.get("DDN_S3_PRESIGN_EXPIRES", "3600"))
REGION = os.environ.get("AWS_REGION", "ap-northeast-2")

s3 = boto3.client(
    "s3",
    region_name=REGION,
    config=Config(s3={"use_accelerate_endpoint": ACCELERATE})
)

def lambda_handler(event, context):
    # Get Query parameters from the event
    params = event.get("queryStringParameters", {}) or {}
    file_name = params.get("file")
    mode = params.get("mode", "download")  # get mode (upload / download)

    if not file_name:
        return {"statusCode": 400, "body": "file parameter is required"}

    if mode == "upload":
        bucket = os.environ["DDN_IN_BUCKET"]
        method = "put_object"
    else:
        bucket = os.environ["DDN_OUT_BUCKET"]
        method = "get_object"

    try:
        url = s3.generate_presigned_url(
            ClientMethod=method,
            Params={"Bucket": bucket, "Key": file_name},
            ExpiresIn=EXPIRES  # 1 hour
        )
        return {"statusCode": 200, "body": json.dumps({"url": url})}
    except Exception as e:
        # return {"statusCode": 500, "body": str(e)}
        return {"statusCode": 500, "body": "Error generating presigned URL"}