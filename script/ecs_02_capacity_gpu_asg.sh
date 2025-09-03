#!/usr/bin/env bash
set -euo pipefail
source .env
aws configure set region "$AWS_REGION"

# ECS Optimized GPU AMI (AL2) 최신 이미지 ID 조회
AMI_ID=$(aws ssm get-parameters --names /aws/service/ecs/optimized-ami/amazon-linux-2/gpu/recommended/image_id \
  --query 'Parameters[0].Value' --output text)
echo "[INFO] Using ECS GPU AMI: $AMI_ID"

# SG 생성: ECS 인스턴스용
ECS_SG_ID=$(aws ec2 create-security-group \
  --vpc-id "$DDN_VPC_ID" \
  --group-name "$DDN_ECS_SG_NAME" \
  --description "ECS GPU instances SG" \
  --query 'GroupId' --output text 2>/dev/null || true)

if [ -z "${ECS_SG_ID:-}" ]; then
  ECS_SG_ID=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$DDN_VPC_ID" "Name=group-name,Values=$DDN_ECS_SG_NAME" --query 'SecurityGroups[0].GroupId' --output text)
fi
echo "[INFO] ECS SG: $ECS_SG_ID"

# 인바운드는 ALB SG만 허용. 일단 비워두고 뒤에서 ALB SG랑 연결
aws ec2 authorize-security-group-egress --group-id "$ECS_SG_ID" --ip-permissions 'IpProtocol=-1,IpRanges=[{CidrIp=0.0.0.0/0}]' >/dev/null 2>/dev/null || true

# 서브넷 파싱
IFS=',' read -r SUBNET1 SUBNET2 <<< "$DDN_SUBNET_IDS"

# Launch Template
USERDATA=$(cat <<EOF
#!/bin/bash
echo ECS_CLUSTER=${DDN_ECS_CLUSTER} >> /etc/ecs/ecs.config
EOF
)

LT_ID=$(aws ec2 create-launch-template \
  --launch-template-name "$DDN_LAUNCH_TEMPLATE_NAME" \
  --launch-template-data "{
    \"ImageId\": \"$AMI_ID\",
    \"InstanceType\": \"$DDN_INSTANCE_TYPE\",
    \"IamInstanceProfile\": {\"Name\": \"ecsInstanceRole\"},
    \"SecurityGroupIds\": [\"$ECS_SG_ID\"],
    \"UserData\": \"$(echo -n "$USERDATA" | base64 -w0)\"
  }" \
  --query 'LaunchTemplate.LaunchTemplateId' --output text 2>/dev/null || true)

if [ -z "${LT_ID:-}" ]; then
  LT_ID=$(aws ec2 describe-launch-templates --launch-template-names "$DDN_LAUNCH_TEMPLATE_NAME" --query 'LaunchTemplates[0].LaunchTemplateId' --output text)
fi
echo "[INFO] LaunchTemplate: $LT_ID"

# ASG 생성
aws autoscaling create-auto-scaling-group \
  --auto-scaling-group-name "$DDN_ASG_NAME" \
  --launch-template "LaunchTemplateId=$LT_ID,Version=\$Latest" \
  --min-size "$DDN_MIN_SIZE" --desired-capacity "$DDN_DESIRED_SIZE" --max-size "$DDN_MAX_SIZE" \
  --vpc-zone-identifier "$DDN_SUBNET_IDS" >/dev/null 2>/dev/null || true

echo "[OK] ASG created."

# Capacity Provider 연결
aws ecs create-capacity-provider \
  --name "${DDN_ASG_NAME}-cp" \
  --auto-scaling-group-provider "autoScalingGroupArn=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $DDN_ASG_NAME --query 'AutoScalingGroups[0].AutoScalingGroupARN' --output text),managedScaling={status=ENABLED,targetCapacity=100,minimumScalingStepSize=1,maximumScalingStepSize=1},managedTerminationProtection=DISABLED" >/dev/null 2>/dev/null || true

aws ecs put-cluster-capacity-providers \
  --cluster "$DDN_ECS_CLUSTER" \
  --capacity-providers "${DDN_ASG_NAME}-cp" \
  --default-capacity-provider-strategy capacityProvider="${DDN_ASG_NAME}-cp",weight=1 >/dev/null

echo "[OK] Capacity Provider attached."
