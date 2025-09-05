#!/usr/bin/env bash
set -euo pipefail
source .env

command -v aws >/dev/null || { echo "[ERROR] aws CLI not found"; exit 1; }
aws sts get-caller-identity >/dev/null || { echo "[ERROR] AWS credentials not configured"; exit 1; }

echo "[OK] AWS CLI and credentials ready."
echo "[INFO] Region: $AWS_REGION, Account: $ACCOUNT_ID"

# 1. Role 확인 및 생성
if ! aws iam get-role --role-name $DDN_ECS_ROLE_NAME >/dev/null 2>&1; then
  echo "[INFO] Creating IAM Role: $DDN_ECS_ROLE_NAME"
  aws iam create-role \
    --role-name $DDN_ECS_ROLE_NAME \
    --assume-role-policy-document '{
      "Version": "2008-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "Principal": { "Service": "ec2.amazonaws.com" },
          "Action": "sts:AssumeRole"
        }
      ]
    }'
else
  echo "[INFO] IAM Role already exists: $DDN_ECS_ROLE_NAME"
fi

# 2. 정책 연결 (중복 attach는 에러 안 나고 무시됨)
aws iam attach-role-policy \
  --role-name $DDN_ECS_ROLE_NAME \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role

# 3. Instance Profile 확인 및 생성
if ! aws iam get-instance-profile --instance-profile-name $DDN_ECS_PROFILE_NAME >/dev/null 2>&1; then
  echo "[INFO] Creating Instance Profile: $DDN_ECS_PROFILE_NAME"
  aws iam create-instance-profile --instance-profile-name $DDN_ECS_PROFILE_NAME
else
  echo "[INFO] Instance Profile already exists: $DDN_ECS_PROFILE_NAME"
fi

# 4. Role을 Instance Profile에 추가 (이미 있으면 에러 → 무시)
if ! aws iam get-instance-profile --instance-profile-name $DDN_ECS_PROFILE_NAME \
  --query "InstanceProfile.Roles[?RoleName=='$DDN_ECS_ROLE_NAME']" --output text | grep -q "$DDN_ECS_ROLE_NAME"; then
  echo "[INFO] Adding Role to Instance Profile"
  aws iam add-role-to-instance-profile \
    --instance-profile-name $DDN_ECS_PROFILE_NAME \
    --role-name $DDN_ECS_ROLE_NAME
else
  echo "[INFO] Role already attached to Instance Profile"
fi

echo "[OK] IAM prerequisites ready: $DDN_ECS_ROLE_NAME / $DDN_ECS_PROFILE_NAME"