#!/usr/bin/env bash
set -euo pipefail
source .env

echo "[INFO] Installing required packages (gettext, jq)..."
sudo yum install -y -q gettext jq

command -v aws >/dev/null || { echo "[ERROR] aws CLI not found"; exit 1; }
aws sts get-caller-identity >/dev/null || { echo "[ERROR] AWS credentials not configured"; exit 1; }

echo "[OK] AWS CLI and credentials ready."
echo "[INFO] Region: $AWS_REGION, Account: $ACCOUNT_ID"

# 1. ECS Instance Role (EC2 -> ECS Agent)
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

if ! aws iam get-instance-profile --instance-profile-name $DDN_ECS_PROFILE_NAME >/dev/null 2>&1; then
  echo "[INFO] Creating Instance Profile: $DDN_ECS_PROFILE_NAME"
  aws iam create-instance-profile --instance-profile-name $DDN_ECS_PROFILE_NAME
fi

if ! aws iam get-instance-profile --instance-profile-name $DDN_ECS_PROFILE_NAME \
  --query "InstanceProfile.Roles[?RoleName=='$DDN_ECS_ROLE_NAME']" --output text | grep -q "$DDN_ECS_ROLE_NAME"; then
  echo "[INFO] Adding Role to Instance Profile"
  aws iam add-role-to-instance-profile \
    --instance-profile-name $DDN_ECS_PROFILE_NAME \
    --role-name $DDN_ECS_ROLE_NAME
else
  echo "[INFO] Role already attached to Instance Profile"
fi

# 3. ECS Task Execution Role (ECR Pull, Logs)
if ! aws iam get-role --role-name $DDN_ECS_EXECUTION_ROLE_NAME >/dev/null 2>&1; then
  echo "[INFO] Creating IAM Role: $DDN_ECS_EXECUTION_ROLE_NAME"
  aws iam create-role \
    --role-name $DDN_ECS_EXECUTION_ROLE_NAME  \
    --assume-role-policy-document '{
      "Version": "2012-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "Principal": { "Service": "ecs-tasks.amazonaws.com" },
          "Action": "sts:AssumeRole"
        }
      ]
    }'
else
  echo "[INFO] IAM Role already exists: $DDN_ECS_EXECUTION_ROLE_NAME"
fi

aws iam attach-role-policy \
  --role-name $DDN_ECS_EXECUTION_ROLE_NAME \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy

# 4. ECS Task Role (App code -> S3 Access)
if ! aws iam get-role --role-name $DDN_ECS_TASK_ROLE_NAME >/dev/null 2>&1; then
  echo "[INFO] Creating IAM Role: $DDN_ECS_TASK_ROLE_NAME"
  aws iam create-role \
    --role-name $DDN_ECS_TASK_ROLE_NAME \
    --assume-role-policy-document '{
      "Version": "2012-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "Principal": { "Service": "ecs-tasks.amazonaws.com" },
          "Action": "sts:AssumeRole"
        }
      ]
    }'
else
  echo "[INFO] IAM Role already exists: $DDN_ECS_TASK_ROLE_NAME"
fi

# 최소한 S3 접근 권한 추가
aws iam put-role-policy \
  --role-name $DDN_ECS_TASK_ROLE_NAME \
  --policy-name $DDN_ECS_TASK_POLICY_NAME \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {
        \"Effect\": \"Allow\",
        \"Action\": [\"s3:GetObject\", \"s3:PutObject\"],
        \"Resource\": [
          \"arn:aws:s3:::${DDN_IN_BUCKET}/*\",
          \"arn:aws:s3:::${DDN_OUT_BUCKET}/*\"
        ]
      }
    ]
  }"

echo "[OK] IAM prerequisites ready:"
echo " - Instance Role/Profile: $DDN_ECS_ROLE_NAME / $DDN_ECS_PROFILE_NAME"
echo " - Task Execution Role: ecsTaskExecutionRole"
echo " - Task Role (S3 Access): ddnTaskRole"