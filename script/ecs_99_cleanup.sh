#!/usr/bin/env bash
set -euo pipefail
source .env
aws configure set region "$AWS_REGION"

# ---------------------------------------------------------
# 1. ECS 서비스 스케일 다운 및 삭제
# ---------------------------------------------------------
echo "[STEP 1] Stop and delete ECS Service..."
set +e
aws ecs update-service \
  --cluster "$DDN_ECS_CLUSTER" \
  --service "$DDN_ECS_SERVICE" \
  --desired-count 0 >/dev/null 2>&1

aws ecs delete-service \
  --cluster "$DDN_ECS_CLUSTER" \
  --service "$DDN_ECS_SERVICE" \
  --force >/dev/null 2>&1
set -e

# 서비스 삭제 완료 대기 (최대 3회)
echo "[INFO] Briefly waiting for ECS service to disappear or become INACTIVE..."
for i in {1..3}; do
  # 클러스터 존재 여부 확인
  CLUSTER_STATUS=$(aws ecs describe-clusters \
    --clusters "$DDN_ECS_CLUSTER" \
    --query 'clusters[0].status' --output text 2>/dev/null || echo "NOT_FOUND")

  if [ "$CLUSTER_STATUS" = "INACTIVE" ] || [ "$CLUSTER_STATUS" = "NOT_FOUND" ] || [ "$CLUSTER_STATUS" = "None" ]; then
    echo "[OK] Cluster not found or already deleted. Skipping service wait."
    break
  fi

  # 서비스 상세 조회
  DESC_JSON=$(aws ecs describe-services \
    --cluster "$DDN_ECS_CLUSTER" \
    --services "$DDN_ECS_SERVICE" 2>/dev/null || true)

  if [ -z "$DESC_JSON" ]; then
    echo "[OK] Service not found (describe-services failed)."
    break
  fi

  STATUS=$(echo "$DESC_JSON" | jq -r '.services[0].status // "None"' 2>/dev/null || echo "None")
  RUNNING=$(echo "$DESC_JSON" | jq -r '.services[0].runningCount // 0' 2>/dev/null || echo 0)
  PENDING=$(echo "$DESC_JSON" | jq -r '.services[0].pendingCount // 0' 2>/dev/null || echo 0)
  FAILURES_LEN=$(echo "$DESC_JSON" | jq -r '.failures | length' 2>/dev/null || echo 0)

  if [ "$FAILURES_LEN" != "0" ] || [ "$STATUS" = "None" ] || [ "$STATUS" = "INACTIVE" ]; then
    echo "[OK] Service is gone or INACTIVE."
    break
  fi

  # Task가 남아 있으면 강제 종료
  if [ "$RUNNING" -gt 0 ] || [ "$PENDING" -gt 0 ]; then
    TASK_ARNS=$(aws ecs list-tasks --cluster "$DDN_ECS_CLUSTER" --service-name "$DDN_ECS_SERVICE" \
      --query 'taskArns[]' --output text 2>/dev/null || echo "")
    if [ -n "$TASK_ARNS" ]; then
      echo "[INFO] Stopping remaining tasks attached to the service: $TASK_ARNS"
      for T in $TASK_ARNS; do
        aws ecs stop-task --cluster "$DDN_ECS_CLUSTER" --task "$T" >/dev/null 2>&1 || true
      done
    fi
  fi

  echo "[INFO] Service status=$STATUS running=$RUNNING pending=$PENDING ... waiting 10s"
  sleep 10
done

# ---------------------------------------------------------
# 2. 서비스 외 남아있는 태스크 강제 정리
# ---------------------------------------------------------
echo "[STEP 2] Force stop any remaining cluster-level tasks..."
TASK_ARNS=$(aws ecs list-tasks --cluster "$DDN_ECS_CLUSTER" \
  --query 'taskArns[]' --output text 2>/dev/null || echo "")
if [ -n "$TASK_ARNS" ]; then
  for T in $TASK_ARNS; do
    aws ecs stop-task --cluster "$DDN_ECS_CLUSTER" --task "$T" >/dev/null 2>&1 || true
  done
else
  echo "[INFO] No standalone tasks found."
fi

# ---------------------------------------------------------
# 3. Auto Scaling 그룹 삭제
# ---------------------------------------------------------
echo "[STEP 3] Delete Auto Scaling Group..."
ASG_EXIST=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$DDN_ASG_NAME" \
  --query 'AutoScalingGroups[0].AutoScalingGroupName' \
  --output text 2>/dev/null || echo "None")

if [ "$ASG_EXIST" != "None" ] && [ -n "$ASG_EXIST" ]; then
  echo "[INFO] ASG found: $ASG_EXIST"
  aws autoscaling update-auto-scaling-group \
    --auto-scaling-group-name "$DDN_ASG_NAME" \
    --min-size 0 --desired-capacity 0

  sleep 10
  aws autoscaling delete-auto-scaling-group \
    --auto-scaling-group-name "$DDN_ASG_NAME" \
    --force-delete >/dev/null 2>&1 || true
  echo "[OK] Auto Scaling Group deleted."
else
  echo "[INFO] Auto Scaling Group not found. Skipping."
fi

# ---------------------------------------------------------
# 4. EC2 인스턴스 종료 대기
# ---------------------------------------------------------
echo "[STEP 4] Wait for EC2 instances termination..."
INSTANCE_IDS=$(aws ec2 describe-instances \
  --filters "Name=tag:aws:autoscaling:groupName,Values=$DDN_ASG_NAME" \
  --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || echo "")

if [ -n "$INSTANCE_IDS" ]; then
  aws ec2 wait instance-terminated --instance-ids $INSTANCE_IDS
  echo "[OK] All instances terminated."
else
  echo "[INFO] No instances found."
fi

# ---------------------------------------------------------
# 5. Launch Template 삭제
# ---------------------------------------------------------
echo "[STEP 5] Delete Launch Template..."
LT_ID=$(aws ec2 describe-launch-templates \
  --launch-template-names "$DDN_LAUNCH_TEMPLATE_NAME" \
  --query 'LaunchTemplates[0].LaunchTemplateId' --output text 2>/dev/null || echo "None")

if [ "$LT_ID" != "None" ]; then
  aws ec2 delete-launch-template --launch-template-name "$DDN_LAUNCH_TEMPLATE_NAME"
  echo "[OK] Launch Template deleted: $DDN_LAUNCH_TEMPLATE_NAME"
else
  echo "[INFO] Launch Template not found."
fi

# ---------------------------------------------------------
# 6. 컨테이너 인스턴스 강제 Deregister
# ---------------------------------------------------------
echo "[STEP 6] Deregister container instances..."
CI_ARNS=$(aws ecs list-container-instances --cluster "$DDN_ECS_CLUSTER" \
  --query 'containerInstanceArns[]' --output text 2>/dev/null || echo "")
if [ -n "$CI_ARNS" ]; then
  for CI in $CI_ARNS; do
    aws ecs deregister-container-instance \
      --cluster "$DDN_ECS_CLUSTER" \
      --container-instance "$CI" \
      --force >/dev/null 2>&1 || true
  done
  echo "[OK] Container instances deregistered."
else
  echo "[INFO] No container instances found."
fi

# ---------------------------------------------------------
# 7. 용량 프로바이더 해제 및 삭제
# ---------------------------------------------------------
echo "[STEP 7] Detach and delete capacity providers..."
aws ecs put-cluster-capacity-providers \
  --cluster "$DDN_ECS_CLUSTER" \
  --capacity-providers [] \
  --default-capacity-provider-strategy [] >/dev/null 2>&1 || true

aws ecs delete-capacity-provider --capacity-provider "${DDN_ASG_NAME}-cp" >/dev/null 2>&1 || true
echo "[OK] Capacity provider detached or deleted (if existed)."

# ---------------------------------------------------------
# 7.1. 클러스터 어태치먼트 업데이트 완료 대기
# ---------------------------------------------------------
echo "[WAIT] Wait for cluster attachments update to complete..."
for i in {1..18}; do  # 최대 3분(10s x 18) 정도 대기
  ATTACH_UPDATING=$(aws ecs describe-clusters \
    --clusters "$DDN_ECS_CLUSTER" \
    --include ATTACHMENTS \
    --query 'length(clusters[0].attachments[?status==`UPDATE_IN_PROGRESS`])' \
    --output text 2>/dev/null || echo "0")

  # 용량 프로바이더가 비워졌는지도 한번 더 확인(방어적)
  CP_COUNT=$(aws ecs list-cluster-capacity-providers \
    --cluster "$DDN_ECS_CLUSTER" \
    --query 'length(capacityProviders)' \
    --output text 2>/dev/null || echo "0")

  if [ "$ATTACH_UPDATING" = "0" ] && [ "$CP_COUNT" = "0" ]; then
    echo "[OK] Cluster attachments updated and capacity providers detached."
    break
  fi

  echo "[INFO] attachments updating: $ATTACH_UPDATING, cp_count: $CP_COUNT ... waiting 10s"
  sleep 10
done

# ---------------------------------------------------------
# 8. 로그 그룹 삭제
# ---------------------------------------------------------
echo "[STEP 8] Delete CloudWatch Log Group..."
aws logs delete-log-group --log-group-name "/ecs/$DDN_ECS_TASK_FAMILY" >/dev/null 2>&1 || true

# ---------------------------------------------------------
# 9. ECS 전용 보안 그룹만 삭제 (ALB SG는 제외) - 필요 시 사용
# ---------------------------------------------------------
# echo "[STEP 9] Delete ECS Security Group..."
# ECS_SG_ID=$(aws ec2 describe-security-groups \
#   --filters "Name=vpc-id,Values=$DDN_VPC_ID" "Name=group-name,Values=$DDN_ECS_SG_NAME" \
#   --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")
# if [ "$ECS_SG_ID" != "None" ]; then
#   ENI_IDS=$(aws ec2 describe-network-interfaces \
#     --filters "Name=group-id,Values=$ECS_SG_ID" \
#     --query 'NetworkInterfaces[].NetworkInterfaceId' --output text)
#   for ENI in $ENI_IDS; do
#     aws ec2 delete-network-interface --network-interface-id "$ENI" >/dev/null 2>&1 || true
#   done
#   aws ec2 delete-security-group --group-id "$ECS_SG_ID"
#   echo "[OK] ECS Security Group deleted: $DDN_ECS_SG_NAME"
# else
#   echo "[INFO] ECS Security Group not found or already deleted."
# fi

# ---------------------------------------------------------
# 10. 마지막. ECS 클러스터 삭제
# ---------------------------------------------------------
echo "[FINAL] Delete ECS Cluster..."
# 혹시 남아있을 컨테이너 인스턴스가 있으면 한 번 더 Deregister 시도
CI_ARNS=$(aws ecs list-container-instances --cluster "$DDN_ECS_CLUSTER" \
  --query 'containerInstanceArns[]' --output text 2>/dev/null || echo "")
if [ -n "$CI_ARNS" ]; then
  for CI in $CI_ARNS; do
    aws ecs deregister-container-instance \
      --cluster "$DDN_ECS_CLUSTER" \
      --container-instance "$CI" \
      --force >/dev/null 2>&1 || true
  done
fi

aws ecs delete-cluster \
  --cluster "$DDN_ECS_CLUSTER" \
  --query 'cluster.status' \
  --output text || echo "[WARN] Cluster may already be deleted."

echo "[✅ DONE] ECS/ASG/LaunchTemplate cleanup completed. ALB/TargetGroup cleanup is handled separately."
