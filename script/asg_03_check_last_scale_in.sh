#!/usr/bin/env bash
set -euo pipefail
set -a; source .env; set +a

RAW_ACTS=$(aws application-autoscaling describe-scaling-activities \
  --region "$AWS_REGION" --service-namespace ecs \
  --resource-id service/$DDN_ECS_CLUSTER/$DDN_ECS_SERVICE \
  --max-results 20)

# 최근 성공 활동들 중 desired가 감소한 케이스(또는 Cause에 ScaleIn/AlarmLow 흔적)를 선택
LAST_IN_JSON=$(
  echo "$RAW_ACTS" | jq -c '
    .ScalingActivities
    | map(select(.StatusCode=="Successful"))
    | sort_by(.StartTime)
    | reduce .[] as $a (
        {prevDesired:null, lastIn:null};
        . as $acc
        | ($a.StatusMessage | capture("desired count to (?<d>[0-9]+)"; "i").d | tonumber) as $d
        | ($a.Cause // "") as $cause
        | ($acc.prevDesired) as $p
        | ($p != null and $d < $p
           or ($cause|test("ScaleIn";"i"))
           or ($cause|test("AlarmLow";"i"))
          )
          as $is_in
        | ($a + {desired:$d, is_in:$is_in, prev:$p}) as $curr
        | {
            prevDesired: $d,
            lastIn: (if $is_in then $curr else .lastIn end)
          }
    ).lastIn
  '
)

if [[ -z "${LAST_IN_JSON}" || "${LAST_IN_JSON}" == "null" ]]; then
  echo "[INFO] 최근 Scale IN 성공 활동을 찾지 못했습니다."
  exit 0
fi

START_TS=$(echo "$LAST_IN_JSON" | jq -r '.StartTime')
CAUSE=$(echo "$LAST_IN_JSON" | jq -r '.Cause')
DESIRED=$(echo "$LAST_IN_JSON" | jq -r '.desired')
echo "== Last Scale IN =="
echo "StartTime : $START_TS"
echo "Desired   : $DESIRED"
echo "Cause     : $CAUSE"

ALARM_NAME=$(echo "$CAUSE" | sed -n 's/.*monitor alarm \(.*\) in state.*/\1/p')
POLICY_NAME=$(echo "$CAUSE" | sed -n 's/.*triggered policy \(.*\)$/\1/p')
echo "AlarmName : ${ALARM_NAME:-N/A}"
echo "Policy    : ${POLICY_NAME:-N/A}"

if [[ -n "${ALARM_NAME:-}" ]]; then
  echo "---- Alarm History (state updates) ----"
  aws cloudwatch describe-alarm-history \
    --region "$AWS_REGION" \
    --alarm-name "$ALARM_NAME" \
    --history-item-type StateUpdate \
    --max-items 10 \
  | jq -r '.AlarmHistoryItems[] | [.Timestamp, .HistorySummary] | @tsv'
fi

# 어떤 지표를 보는 알람인지 확인해서 맞는 메트릭을 뽑아보자
# (1) ALB RequestCountPerTarget인 경우
ALARM_DESC=$(aws cloudwatch describe-alarms --region "$AWS_REGION" --alarm-names "$ALARM_NAME" \
  | jq -c '.MetricAlarms[0]')

NS=$(echo "$ALARM_DESC" | jq -r '.Metrics[0].MetricStat.Metric.Namespace // .Namespace')
MN=$(echo "$ALARM_DESC" | jq -r '.Metrics[0].MetricStat.Metric.MetricName // .MetricName')

echo "---- Metric window around activity ----"
END=$(date -u -d "${START_TS} + 2 minutes" +%Y-%m-%dT%H:%M:%SZ)
START=$(date -u -d "${START_TS} - 8 minutes" +%Y-%m-%dT%H:%M:%SZ)
echo "Window: $START ~ $END (UTC)"

if [[ "$NS" == "AWS/ApplicationELB" && "$MN" == "RequestCountPerTarget" ]]; then
  LB_ARN=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" --names "$DDN_ALB_NAME" --query 'LoadBalancers[0].LoadBalancerArn' --output text)
  TG_ARN=$(aws elbv2 describe-target-groups   --region "$AWS_REGION" --names "$DDN_TG_FLASK"  --query 'TargetGroups[0].TargetGroupArn'  --output text)
  LB_LABEL=$(echo "$LB_ARN" | sed -E 's|^arn:aws:elasticloadbalancing:[^:]+:[^:]+:loadbalancer/||')
  TG_LABEL=$(echo "$TG_ARN" | sed -E 's|^arn:aws:elasticloadbalancing:[^:]+:[^:]+:||')

  aws cloudwatch get-metric-statistics \
    --region "$AWS_REGION" \
    --namespace AWS/ApplicationELB \
    --metric-name RequestCountPerTarget \
    --dimensions Name=LoadBalancer,Value="$LB_LABEL" Name=TargetGroup,Value="$TG_LABEL" \
    --start-time "$START" --end-time "$END" --period 60 --statistics Sum \
  | jq -r '.Datapoints | sort_by(.Timestamp)
           | map("\(.Timestamp)  Sum=\(.Sum)") | .[]'
elif [[ "$NS" == "AWS/ECS" && "$MN" == "CPUUtilization" ]]; then
  aws cloudwatch get-metric-statistics \
    --region "$AWS_REGION" \
    --namespace AWS/ECS \
    --metric-name CPUUtilization \
    --dimensions Name=ClusterName,Value="$DDN_ECS_CLUSTER" Name=ServiceName,Value="$DDN_ECS_SERVICE" \
    --start-time "$START" --end-time "$END" --period 60 --statistics Average \
  | jq -r '.Datapoints | sort_by(.Timestamp)
           | map("\(.Timestamp)  CPU_Avg=\(.Average)") | .[]'
elif [[ "$NS" == "AWS/ECS" && "$MN" == "MemoryUtilization" ]]; then
  aws cloudwatch get-metric-statistics \
    --region "$AWS_REGION" \
    --namespace AWS/ECS \
    --metric-name MemoryUtilization \
    --dimensions Name=ClusterName,Value="$DDN_ECS_CLUSTER" Name=ServiceName,Value="$DDN_ECS_SERVICE" \
    --start-time "$START" --end-time "$END" --period 60 --statistics Average \
  | jq -r '.Datapoints | sort_by(.Timestamp)
           | map("\(.Timestamp)  MEM_Avg=\(.Average)") | .[]'
else
  echo "[INFO] 이 알람은 Metric Math/복합일 수 있습니다. 위 Alarm History로 상태 전환 시각을 확인하세요."
fi

echo "---- ECS Service snapshot ----"
aws ecs describe-services --region "$AWS_REGION" \
  --cluster "$DDN_ECS_CLUSTER" --services "$DDN_ECS_SERVICE" \
| jq -r '.services[0] | {desiredCount,runningCount,pendingCount,events: .events[:5]}'
echo "[✅ DONE] Last Scale IN check completed."