#!/usr/bin/env bash
set -euo pipefail

# 0) env
set -a; source .env; set +a

RAW_ACTS="$(aws application-autoscaling describe-scaling-activities \
  --region "$AWS_REGION" --service-namespace ecs \
  --resource-id service/$DDN_ECS_CLUSTER/$DDN_ECS_SERVICE \
  --max-results 50)"

# 1) 최근 활동에서 "ScaleIn/AlarmLow/감소" 흔적이 있는 마지막 1건
LAST_IN_JSON="$(
  printf '%s' "$RAW_ACTS" | jq -c '
    .ScalingActivities
    | map(select(.StatusCode=="Successful"))
    | sort_by(.StartTime)
    | ( . as $all
        | map(. + { desired: ((.StatusMessage|capture("desired count to (?<d>[0-9]+)"; "i").d // "NaN") | tonumber?) })
      )
    | reverse
    | map(select(.Cause | test("ScaleIn|AlarmLow"; "i")))
    | first?    
  '
)"

if [[ -z "${LAST_IN_JSON}" || "${LAST_IN_JSON}" == "null" ]]; then
  echo "[INFO] 최근 Scale IN 성공 활동을 찾지 못했습니다."
  exit 0
fi

START_TS="$(printf '%s' "$LAST_IN_JSON" | jq -r '.StartTime')"
CAUSE="$(printf '%s' "$LAST_IN_JSON" | jq -r '.Cause')"
DESIRED="$(printf '%s' "$LAST_IN_JSON" | jq -r '.desired')"

echo "== Last Scale IN =="
echo "StartTime : $START_TS"
echo "Desired   : ${DESIRED:-N/A}"
echo "Cause     : $CAUSE"

ALARM_NAME="$(printf '%s' "$CAUSE" | sed -n 's/.*monitor alarm \(.*\) in state.*/\1/p')"
POLICY_NAME="$(printf '%s' "$CAUSE" | sed -n 's/.*triggered policy \(.*\)$/\1/p')"
echo "AlarmName : ${ALARM_NAME:-N/A}"
echo "Policy    : ${POLICY_NAME:-N/A}"

# 2) 알람 히스토리
if [[ -n "${ALARM_NAME:-}" ]]; then
  echo "---- Alarm History (state updates) ----"
  aws cloudwatch describe-alarm-history \
    --region "$AWS_REGION" \
    --alarm-name "$ALARM_NAME" \
    --history-item-type StateUpdate \
    --max-items 10 \
  | jq -r '.AlarmHistoryItems[] | [.Timestamp, .HistorySummary] | @tsv'
fi

# 3) 알람이 보는 메트릭에 맞춰 창 주변 지표 출력
END="$(date -u -d "${START_TS} + 2 minutes" +%Y-%m-%dT%H:%M:%SZ)"
START="$(date -u -d "${START_TS} - 8 minutes" +%Y-%m-%dT%H:%M:%SZ)"
echo "Window: $START ~ $END (UTC)"

ALARM_DESC="$(aws cloudwatch describe-alarms --region "$AWS_REGION" --alarm-names "$ALARM_NAME" | jq -c '.MetricAlarms[0]')"
NS="$(
  printf '%s' "$ALARM_DESC" | jq -r '
    # 매스 알람(.Metrics[0]...)을 먼저 시도하고, 없으면 단일 알람(.Namespace/.MetricName)으로 폴백
    try .Metrics[0].MetricStat.Metric.Namespace catch (.Namespace // .Metric.Namespace // empty)
  '
)"

MN="$(
  printf '%s' "$ALARM_DESC" | jq -r '
    try .Metrics[0].MetricStat.Metric.MetricName  catch (.MetricName // .Metric.MetricName // empty)
  '
)"

if [[ "$NS" == "AWS/ApplicationELB" && "$MN" == "RequestCountPerTarget" ]]; then
  LB_ARN="$(aws elbv2 describe-load-balancers --region "$AWS_REGION" --names "$DDN_ALB_NAME" --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
  TG_ARN="$(aws elbv2 describe-target-groups   --region "$AWS_REGION" --names "$DDN_TG_FLASK"  --query 'TargetGroups[0].TargetGroupArn'  --output text)"
  LB_LABEL="$(printf '%s' "$LB_ARN" | sed -E 's|^arn:aws:elasticloadbalancing:[^:]+:[^:]+:loadbalancer/||')"
  TG_LABEL="$(printf '%s' "$TG_ARN" | sed -E 's|^arn:aws:elasticloadbalancing:[^:]+:[^:]+:||')"

  echo "---- Metric (RequestCountPerTarget Sum / 60s) ----"
  aws cloudwatch get-metric-statistics \
    --region "$AWS_REGION" \
    --namespace AWS/ApplicationELB \
    --metric-name RequestCountPerTarget \
    --dimensions Name=LoadBalancer,Value="$LB_LABEL" Name=TargetGroup,Value="$TG_LABEL" \
    --start-time "$START" --end-time "$END" --period 60 --statistics Sum \
  | jq -r '.Datapoints | sort_by(.Timestamp) | map("\(.Timestamp)  Sum=\(.Sum)") | .[]'
elif [[ "$NS" == "AWS/ECS" && "$MN" == "CPUUtilization" ]]; then
  echo "---- Metric (ECS CPU Average / 60s) ----"
  aws cloudwatch get-metric-statistics \
    --region "$AWS_REGION" \
    --namespace AWS/ECS \
    --metric-name CPUUtilization \
    --dimensions Name=ClusterName,Value="$DDN_ECS_CLUSTER" Name=ServiceName,Value="$DDN_ECS_SERVICE" \
    --start-time "$START" --end-time "$END" --period 60 --statistics Average \
  | jq -r '.Datapoints | sort_by(.Timestamp) | map("\(.Timestamp)  CPU_Avg=\(.Average)") | .[]'
elif [[ "$NS" == "AWS/ECS" && "$MN" == "MemoryUtilization" ]]; then
  echo "---- Metric (ECS Memory Average / 60s) ----"
  aws cloudwatch get-metric-statistics \
    --region "$AWS_REGION" \
    --namespace AWS/ECS \
    --metric-name MemoryUtilization \
    --dimensions Name=ClusterName,Value="$DDN_ECS_CLUSTER" Name=ServiceName,Value="$DDN_ECS_SERVICE" \
    --start-time "$START" --end-time "$END" --period 60 --statistics Average \
  | jq -r '.Datapoints | sort_by(.Timestamp) | map("\(.Timestamp)  MEM_Avg=\(.Average)") | .[]'
else
  echo "[INFO] Metric type를 자동 판별하지 못했습니다. Alarm History로 상태 전환 시각을 확인하세요."
fi

echo "---- ECS Service snapshot ----"
aws ecs describe-services --region "$AWS_REGION" \
  --cluster "$DDN_ECS_CLUSTER" --services "$DDN_ECS_SERVICE" \
| jq -r '.services[0] | {desiredCount,runningCount,pendingCount,events: .events[:5]}'
