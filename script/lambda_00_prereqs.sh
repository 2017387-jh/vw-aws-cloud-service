#!/usr/bin/env bash
set -euo pipefail
source .env

echo "[INFO] Create IAM Role for Lambda: $DDN_LAMBDA_ROLE"

aws iam create-role \
  --role-name $DDN_LAMBDA_ROLE \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": { "Service": "lambda.amazonaws.com" },
        "Action": "sts:AssumeRole"
      }
    ]
  }'

echo "[INFO] Attach S3 FullAccess policy (upload/download)"
aws iam attach-role-policy \
  --role-name $DDN_LAMBDA_ROLE \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess