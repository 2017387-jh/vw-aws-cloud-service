#!/usr/bin/env bash
set -euo pipefail
source .env
aws configure set region "$AWS_REGION"

echo "[INFO] Register ECS Service Auto Scaling target"

# Register Scalable Target
aws application-autoscaling register-scalable-target \
  --service-namespace ecs \
  --scalable-dimension ecs:service:DesiredCount \
  --resource-id service/$DDN_ECS_CLUSTER/$DDN_ECS_SERVICE \
  --min-capacity $DDN_MIN_CAPACITY \
  --max-capacity $DDN_MAX_CAPACITY

echo "[INFO] Attach scaling policy: CPU utilization 70%"

# CPU Based Target Tracking Policy
aws application-autoscaling put-scaling-policy \
  --service-namespace ecs \
  --scalable-dimension ecs:service:DesiredCount \
  --resource-id service/$DDN_ECS_CLUSTER/$DDN_ECS_SERVICE \
  --policy-name "${DDN_ECS_SERVICE}-cpu-scaling" \
  --policy-type TargetTrackingScaling \
  --target-tracking-scaling-policy-configuration "{
    \"TargetValue\": 70.0,
    \"PredefinedMetricSpecification\": {\"PredefinedMetricType\": \"ECSServiceAverageCPUUtilization\"},
    \"ScaleInCooldown\": 60,
    \"ScaleOutCooldown\": 60
  }"

echo "[INFO] Attach scaling policy: Memory utilization 75%"

# Memory Based Target Tracking Policy (Optional)
aws application-autoscaling put-scaling-policy \
  --service-namespace ecs \
  --scalable-dimension ecs:service:DesiredCount \
  --resource-id service/$DDN_ECS_CLUSTER/$DDN_ECS_SERVICE \
  --policy-name "${DDN_ECS_SERVICE}-mem-scaling" \
  --policy-type TargetTrackingScaling \
  --target-tracking-scaling-policy-configuration "{
    \"TargetValue\": 75.0,
    \"PredefinedMetricSpecification\": {\"PredefinedMetricType\": \"ECSServiceAverageMemoryUtilization\"},
    \"ScaleInCooldown\": 60,
    \"ScaleOutCooldown\": 60
  }"

echo "[OK] Auto Scaling policies applied to service: $DDN_ECS_SERVICE"
