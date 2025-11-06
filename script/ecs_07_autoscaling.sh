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

echo "[INFO] Applying ALB RequestCountPerTarget Step Scaling (Sum per minute)..."

# ALB/TG 라벨 계산 (기존 코드와 동일)
LB_ARN=$(aws elbv2 describe-load-balancers \
  --region "$AWS_REGION" \
  --names "$DDN_ALB_NAME" \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text)
TG_ARN=$(aws elbv2 describe-target-groups \
  --region "$AWS_REGION" \
  --names "$DDN_TG_FLASK" \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text)

if [ -z "$LB_ARN" ] || [ "$LB_ARN" = "None" ] || [ -z "$TG_ARN" ] || [ "$TG_ARN" = "None" ]; then
  echo "[ERROR] Failed to retrieve ALB or Target Group ARN."
  exit 1
fi

# CloudWatch 차원 라벨(app/... / targetgroup/...) 추출 (기존과 동일)
LB_LABEL=$(echo "$LB_ARN" | sed -E 's|^arn:aws:elasticloadbalancing:[^:]+:[^:]+:loadbalancer/||')
TG_LABEL=$(echo "$TG_ARN" | sed -E 's|^arn:aws:elasticloadbalancing:[^:]+:[^:]+:||')

# (권장) 기존 타깃트래킹 정책 제거: 3분 연속 조건 제거
aws application-autoscaling delete-scaling-policy \
  --region "$AWS_REGION" \
  --service-namespace ecs \
  --scalable-dimension ecs:service:DesiredCount \
  --resource-id service/$DDN_ECS_CLUSTER/$DDN_ECS_SERVICE \
  --policy-name ddn-ecs-service-alb-rps-scaling \
  >/dev/null 2>&1 || echo "[INFO] TT policy not found, skip"

# Step Scaling (OUT) 정책 생성: 버스트에 즉시 반응
STEP_OUT_ARN=$(aws application-autoscaling put-scaling-policy \
  --region "$AWS_REGION" \
  --service-namespace ecs \
  --resource-id service/$DDN_ECS_CLUSTER/$DDN_ECS_SERVICE \
  --scalable-dimension ecs:service:DesiredCount \
  --policy-name ddn-ecs-stepscale-out-rpm \
  --policy-type StepScaling \
  --step-scaling-policy-configuration "{
    \"AdjustmentType\": \"ChangeInCapacity\",
    \"Cooldown\": ${DDN_SCALE_OUT_COOLDOWN},
    \"MetricAggregationType\": \"Average\",
    \"StepAdjustments\": [
      {\"MetricIntervalLowerBound\": 0, \"MetricIntervalUpperBound\": 40, \"ScalingAdjustment\": 1},
      {\"MetricIntervalLowerBound\": 40, \"MetricIntervalUpperBound\": 80, \"ScalingAdjustment\": 1},
      {\"MetricIntervalLowerBound\": 80, \"ScalingAdjustment\": 2}
    ]
  }" | jq -r '.PolicyARN')

# 분당 합계(Sum) 1분 한 포인트만 넘으면 ALARM → 즉시 스케일 아웃
# 기본 임계는 .env의 DDN_REQUEST_COUNT_PER_TARGET=20.0
aws cloudwatch put-metric-alarm \
  --region "$AWS_REGION" \
  --alarm-name "ddn-ecs-ScaleOut-ReqPerTarget-gt-${DDN_REQUEST_COUNT_PER_TARGET%-*}-1m" \
  --metric-name "RequestCountPerTarget" \
  --namespace "AWS/ApplicationELB" \
  --dimensions Name=LoadBalancer,Value="$LB_LABEL" Name=TargetGroup,Value="$TG_LABEL" \
  --statistic Sum \
  --period 60 \
  --evaluation-periods 1 \
  --threshold "${DDN_SCALE_OUT_THRESHOLD_REQUEST_COUNT}" \
  --comparison-operator GreaterThanThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions "$STEP_OUT_ARN"

# Step Scaling (IN) 정책 생성: 요청 수가 낮을 때 줄이기
STEP_IN_ARN=$(aws application-autoscaling put-scaling-policy \
  --region "$AWS_REGION" \
  --service-namespace ecs \
  --resource-id service/$DDN_ECS_CLUSTER/$DDN_ECS_SERVICE \
  --scalable-dimension ecs:service:DesiredCount \
  --policy-name ddn-ecs-stepscale-in-rpm \
  --policy-type StepScaling \
  --step-scaling-policy-configuration "{
    \"AdjustmentType\": \"ChangeInCapacity\",
    \"Cooldown\": ${DDN_SCALE_IN_COOLDOWN},
    \"MetricAggregationType\": \"Average\",
    \"StepAdjustments\": [
      {\"MetricIntervalUpperBound\": 0, \"ScalingAdjustment\": -1}
    ]
  }" | jq -r '.PolicyARN')

# 요청이 적을 때(DDN_SCALE_IN_REQUEST_COUNT_PER_TARGET 미만 2분 유지) scale-in
aws cloudwatch put-metric-alarm \
  --region "$AWS_REGION" \
  --alarm-name "ddn-ecs-ScaleIn-ReqPerTarget-lt-${DDN_SCALE_IN_REQUEST_COUNT_PER_TARGET}-1m" \
  --metric-name "RequestCountPerTarget" \
  --namespace "AWS/ApplicationELB" \
  --dimensions Name=LoadBalancer,Value="$LB_LABEL" Name=TargetGroup,Value="$TG_LABEL" \
  --statistic Sum \
  --period 60 \
  --evaluation-periods 2 \
  --threshold "${DDN_SCALE_IN_REQUEST_COUNT_PER_TARGET}" \
  --comparison-operator LessThanThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions "$STEP_IN_ARN"

echo "[INFO] Applied StepScaling (IN) policy for low traffic condition"

echo "[OK] Auto Scaling setup complete for service: $DDN_ECS_SERVICE"
echo " - Min Capacity: $DDN_MIN_CAPACITY"
echo " - Max Capacity: $DDN_MAX_CAPACITY"
echo " - CPU High Threshold: $DDN_CPU_HIGH_THRESHOLD%"
echo " - Memory High Threshold: $DDN_MEMORY_HIGH_THRESHOLD%"
echo " - Scale In Cooldown: ${SCALE_IN_COOLDOWN}s"
echo " - Scale Out Cooldown: ${SCALE_OUT_COOLDOWN}s"