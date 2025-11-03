#!/usr/bin/env bash
set -euo pipefail

# Load environment
source .env

echo "[INFO] Start ECS Auto Scaling setup for service: $DDN_ECS_SERVICE in cluster: $DDN_ECS_CLUSTER"

# 기본 Cooldown (없으면 fallback)
SCALE_IN_COOLDOWN="${DDN_SCALE_IN_COOLDOWN:-60}"
SCALE_OUT_COOLDOWN="${DDN_SCALE_OUT_COOLDOWN:-60}"

# Scalable Target 등록 여부 확인
echo "[INFO] Checking existing scalable target..."
if aws application-autoscaling describe-scalable-targets \
  --service-namespace ecs \
  --scalable-dimension ecs:service:DesiredCount \
  --resource-id service/$DDN_ECS_CLUSTER/$DDN_ECS_SERVICE \
  --region "$AWS_REGION" \
  --query 'ScalableTargets' --output text | grep -q "$DDN_ECS_SERVICE"; then
  echo "[INFO] Scalable target already exists. Skipping registration."
else
  echo "[INFO] Registering scalable target..."
  aws application-autoscaling register-scalable-target \
    --service-namespace ecs \
    --scalable-dimension ecs:service:DesiredCount \
    --resource-id service/$DDN_ECS_CLUSTER/$DDN_ECS_SERVICE \
    --min-capacity $DDN_MIN_CAPACITY \
    --max-capacity $DDN_MAX_CAPACITY \
    --region "$AWS_REGION"
fi

# CPU 기반 정책
echo "[INFO] Applying CPU scaling policy (threshold=${DDN_CPU_HIGH_THRESHOLD}%)..."
aws application-autoscaling put-scaling-policy \
  --service-namespace ecs \
  --scalable-dimension ecs:service:DesiredCount \
  --resource-id service/$DDN_ECS_CLUSTER/$DDN_ECS_SERVICE \
  --policy-name "${DDN_ECS_SERVICE}-cpu-scaling" \
  --policy-type TargetTrackingScaling \
  --region "$AWS_REGION" \
  --target-tracking-scaling-policy-configuration "{
    \"TargetValue\": ${DDN_CPU_HIGH_THRESHOLD}.0,
    \"PredefinedMetricSpecification\": {\"PredefinedMetricType\": \"ECSServiceAverageCPUUtilization\"},
    \"ScaleInCooldown\": ${SCALE_IN_COOLDOWN},
    \"ScaleOutCooldown\": ${SCALE_OUT_COOLDOWN}
  }"

# Memory 기반 정책
echo "[INFO] Applying Memory scaling policy (threshold=${DDN_MEMORY_HIGH_THRESHOLD}%)..."
aws application-autoscaling put-scaling-policy \
  --service-namespace ecs \
  --scalable-dimension ecs:service:DesiredCount \
  --resource-id service/$DDN_ECS_CLUSTER/$DDN_ECS_SERVICE \
  --policy-name "${DDN_ECS_SERVICE}-mem-scaling" \
  --policy-type TargetTrackingScaling \
  --region "$AWS_REGION" \
  --target-tracking-scaling-policy-configuration "{
    \"TargetValue\": ${DDN_MEMORY_HIGH_THRESHOLD}.0,
    \"PredefinedMetricSpecification\": {\"PredefinedMetricType\": \"ECSServiceAverageMemoryUtilization\"},
    \"ScaleInCooldown\": ${SCALE_IN_COOLDOWN},
    \"ScaleOutCooldown\": ${SCALE_OUT_COOLDOWN}
  }"

echo "[INFO] Applying ALB RequestCountPerTarget scaling policy (target=3 requests/target)..."

# ALB와 TargetGroup 풀네임 가져오기
ALB_FULL_NAME=$(aws elbv2 describe-load-balancers \
  --region ap-northeast-2 \
  --names ddn-alb \
  --query 'LoadBalancers[0].LoadBalancerFullName' \
  --output text)

TG_FULL_NAME=$(aws elbv2 describe-target-groups \
  --region ap-northeast-2 \
  --names ddn-tg-flask \
  --query 'TargetGroups[0].TargetGroupFullName' \
  --output text)

RESOURCE_LABEL="app/${ALB_FULL_NAME}/${TG_FULL_NAME}"

aws application-autoscaling put-scaling-policy \
  --region ap-northeast-2 \
  --service-namespace ecs \
  --scalable-dimension ecs:service:DesiredCount \
  --resource-id service/ddn-ecs-cluster/ddn-ecs-service \
  --policy-name ddn-ecs-service-alb-rps-scaling \
  --policy-type TargetTrackingScaling \
  --target-tracking-scaling-policy-configuration "{
    \"TargetValue\": 2.0,
    \"PredefinedMetricSpecification\": {
      \"PredefinedMetricType\": \"ALBRequestCountPerTarget\",
      \"ResourceLabel\": \"${RESOURCE_LABEL}\"
    },
    \"ScaleInCooldown\": ${SCALE_IN_COOLDOWN},
    \"ScaleOutCooldown\": ${SCALE_OUT_COOLDOWN}
  }"

echo "[OK] Auto Scaling setup complete for service: $DDN_ECS_SERVICE"
echo " - Min Capacity: $DDN_MIN_CAPACITY"
echo " - Max Capacity: $DDN_MAX_CAPACITY"
echo " - CPU High Threshold: $DDN_CPU_HIGH_THRESHOLD%"
echo " - Memory High Threshold: $DDN_MEMORY_HIGH_THRESHOLD%"
echo " - Scale In Cooldown: ${SCALE_IN_COOLDOWN}s"
echo " - Scale Out Cooldown: ${SCALE_OUT_COOLDOWN}s"