#!/usr/bin/env bash
set -euo pipefail
source .env

aws configure set region "$AWS_REGION"

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

echo "[INFO] Creating S3 Gateway VPC Endpoint for VPC: $DDN_VPC_ID"

# 1) DDN_SUBNET_IDS에 연결된 라우트 테이블 ID들을 수집(중복 제거)
ROUTE_TABLE_IDS=()
IFS=',' read -ra SUBNETS <<< "$DDN_SUBNET_IDS"
for sn in "${SUBNETS[@]}"; do
  rtb=$(aws ec2 describe-route-tables \
    --filters "Name=association.subnet-id,Values=${sn}" \
    --query "RouteTables[0].RouteTableId" --output text)
  [[ -n "$rtb" && "$rtb" != "None" ]] && ROUTE_TABLE_IDS+=("$rtb")
done
# 서브넷이 메인 RTB를 상속 중인 경우 대비: VPC 메인 RTB 추가
MAIN_RTB=$(aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$DDN_VPC_ID" "Name=association.main,Values=true" \
  --query "RouteTables[0].RouteTableId" --output text 2>/dev/null || true)
[[ -n "$MAIN_RTB" && "$MAIN_RTB" != "None" ]] && ROUTE_TABLE_IDS+=("$MAIN_RTB")

# 유니크 처리
mapfile -t ROUTE_TABLE_IDS < <(printf "%s\n" "${ROUTE_TABLE_IDS[@]}" | sort -u)
if [[ ${#ROUTE_TABLE_IDS[@]} -eq 0 ]]; then
  echo "[ERROR] No route tables found for subnets: $DDN_SUBNET_IDS"
  exit 1
fi
echo "[INFO] RouteTables: ${ROUTE_TABLE_IDS[*]}"

# 2) 엔드포인트 존재 여부 확인
EXISTING=$(aws ec2 describe-vpc-endpoints \
  --filters Name=vpc-id,Values="$DDN_VPC_ID" Name=service-name,Values="com.amazonaws.${AWS_REGION}.s3" \
  --query "VpcEndpoints[0].VpcEndpointId" --output text 2>/dev/null || true)

if [[ -n "$EXISTING" && "$EXISTING" != "None" ]]; then
  echo "[INFO] S3 Gateway Endpoint already exists: $EXISTING"
  # 필요 시 라우트 테이블 갱신
  aws ec2 modify-vpc-endpoint --vpc-endpoint-id "$EXISTING" \
    --add-route-table-ids ${ROUTE_TABLE_IDS[@]} >/dev/null || true
else
  echo "[INFO] Creating S3 Gateway Endpoint..."
  # 최초엔 Full Access로 생성 → 동작 확인 후 버킷 제한 정책으로 축소 권장
  EP_ID=$(aws ec2 create-vpc-endpoint \
    --vpc-id "$DDN_VPC_ID" \
    --service-name "com.amazonaws.${AWS_REGION}.s3" \
    --vpc-endpoint-type "Gateway" \
    --route-table-ids ${ROUTE_TABLE_IDS[@]} \
    --policy-document "{
      \"Version\":\"2012-10-17\",
      \"Statement\":[{ \"Effect\":\"Allow\",\"Principal\":\"*\",\"Action\":\"s3:*\",\"Resource\":\"*\"}]
    }" \
    --query "VpcEndpoint.VpcEndpointId" --output text)
  echo "[OK] Created: $EP_ID"
fi

# 3) 상태 체크
aws ec2 describe-vpc-endpoints \
  --filters Name=vpc-id,Values="$DDN_VPC_ID" Name=service-name,Values="com.amazonaws.${AWS_REGION}.s3" \
  --query "VpcEndpoints[0].[VpcEndpointId,State,RouteTableIds]" --output table

echo "[OK] All prerequisites completed."
echo " - ECS Instance Role/Profile: $DDN_ECS_ROLE_NAME / $DDN_ECS_PROFILE_NAME"
echo " - ECS Task Execution Role: $DDN_ECS_EXECUTION_ROLE_NAME"
echo " - ECS Task Role (S3 Access): $DDN_ECS_TASK_ROLE_NAME"
echo " - S3 Gateway VPC Endpoint for VPC $DDN_VPC_ID"
echo "   (Ensure your S3 buckets allow access from this VPC Endpoint for security.)