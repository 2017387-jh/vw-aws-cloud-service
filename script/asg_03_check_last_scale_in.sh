#!/usr/bin/env bash
set -euo pipefail

# 0) env
set -a; source .env; set +a

# 1) 최신 ScalingActivities 가져오기
RAW_ACTS="$(aws application-autoscaling describe-scaling-activities \
  --region "$AWS_REGION" --service-namespace ecs \
  --resource-id service/$DDN_ECS_CLUSTER/$DDN_ECS_SERVICE \
  --max-results 50)"

# 1.1) 최근 활동에서 "ScaleIn/AlarmLow/감소" 흔적이 있는 마지막 1건
LAST_IN_JSON="$(
  printf '%s' "$RAW_ACTS" | jq -c '
    .ScalingActivities
    | map(select(.StatusCode=="Successful"))
    | sort_by(.StartTime)
    | map(. + {
        desired: ((.StatusMessage | capture("desired count to (?<d>[0-9]+)"; "i").d // "NaN") | tonumber?)
      })
    | reverse
    | map(select(.Cause | test("ScaleIn|AlarmLow|lt-[0-9]+-1m|stepscale-in"; "i")))
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

# 2) Cause에서 알람/정책 이름 뽑기
ALARM_NAME="$(printf '%s' "$CAUSE" | sed -n 's/.*monitor alarm \(.*\) in state.*/\1/p')"
POLICY_NAME="$(printf '%s' "$CAUSE" | sed -n 's/.*triggered policy \(.*\)$/\1/p')"
echo "AlarmName : ${ALARM_NAME:-N/A}"
echo "Policy    : ${POLICY_NAME:-N/A}"

# 2.5) 최근 ScalingActivities 타임라인 10건(성공만) — 추가
echo "---- ScalingActivities timeline (last 10, Successful only) ----"
printf '%s' "$RAW_ACTS" | jq -r '
  .ScalingActivities
  | map(select(.StatusCode=="Successful"))
  | sort_by(.StartTime)
  | reverse[:10]
  | map({
      t: .StartTime,
      cause: .Cause,
      msg: .StatusMessage
    })
  | .[]
  | "\(.t)\t\(.cause)\t\(.msg)"
'

# 3) 알람 히스토리 (상태 전환)
if [[ -n "${ALARM_NAME:-}" ]]; then
  echo "---- Alarm History (state updates) ----"
  aws cloudwatch describe-alarm-history \
    --region "$AWS_REGION" \
    --alarm-name "$ALARM_NAME" \
    --history-item-type StateUpdate \
    --max-items 10 \
  | jq -r '.AlarmHistoryItems[] | [.Timestamp, .HistorySummary] | @tsv'
fi

# 4) 알람이 보는 메트릭에 맞춰 창 주변 지표 출력 (-8m ~ +2m)
END="$(date -u -d "${START_TS} + 2 minutes" +%Y-%m-%dT%H:%M:%SZ)"
START="$(date -u -d "${START_TS} - 8 minutes" +%Y-%m-%dT%H:%M:%SZ)"
echo "Window: $START ~ $END (UTC)"

# 4.1) describe-alarms 강화 파싱 (Metric/Composite/MetricMath)
ALARM_JSON="$(aws cloudwatch describe-alarms --region "$AWS_REGION" --alarm-names "$ALARM_NAME")"
ALARM_DESC="$(
  printf '%s' "$ALARM_JSON" \
  | jq -c 'if (.MetricAlarms|length) > 0 then .MetricAlarms[0]
           elif (.CompositeAlarms|length) > 0 then .CompositeAlarms[0]
           else empty end'
)"

if [[ -z "$ALARM_DESC" ]]; then
  echo "[WARN] describe-alarms returned no Metric/Composite alarm for: $ALARM_NAME"
fi

# 4.2) Namespace / MetricName robust 추출
NS="$(
  printf '%s' "$ALARM_DESC" | jq -r '
    (try .Metrics[]?.MetricStat?.Metric?.Namespace catch empty) //
    (.Namespace // empty) //
    (.Metric?.Namespace // empty)
  ' | head -n1
)"

MN="$(
  printf '%s' "$ALARM_DESC" | jq -r '
    (try .Metrics[]?.MetricStat?.Metric?.MetricName catch empty) //
    (.MetricName // empty) //
    (.Metric?.MetricName // empty)
  ' | head -n1
)"

# 4.3) 최후 수단 Fallback (알람명으로 추정)
if [[ -z "$NS" || -z "$MN" ]]; then
  if [[ "$ALARM_NAME" =~ ReqPerTarget ]]; then
    NS="AWS/ApplicationELB"
    MN="RequestCountPerTarget"
    echo "[INFO] Fallback: inferred metric from alarm name -> $NS::$MN"
  fi
fi

# 4.4) 메트릭 출력 (RequestCountPerTarget 우선)
if [[ "$NS" == "AWS/ApplicationELB" && "$MN" == "RequestCountPerTarget" ]]; then
  # ALB/TG 라벨
  LB_ARN="$(aws elbv2 describe-load-balancers --region "$AWS_REGION" --names "$DDN_ALB_NAME" --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
  TG_ARN="$(aws elbv2 describe-target-groups   --region "$AWS_REGION" --names "$DDN_TG_FLASK"  --query 'TargetGroups[0].TargetGroupArn'  --output text)"
  if [[ -z "$LB_ARN" || "$LB_ARN" == "None" || -z "$TG_ARN" || "$TG_ARN" == "None" ]]; then
    echo "[ERROR] Failed to retrieve ALB or Target Group ARN."
    exit 1
  fi
  LB_LABEL="$(printf '%s' "$LB_ARN" | sed -E 's|^arn:aws:elasticloadbalancing:[^:]+:[^:]+:loadbalancer/||')"
  TG_LABEL="$(printf '%s' "$TG_ARN" | sed -E 's|^arn:aws:elasticloadbalancing:[^:]+:[^:]+:||')"

  # Healthy 타깃 수
  HEALTHY_COUNT="$(
    aws elbv2 describe-target-health --region "$AWS_REGION" --target-group-arn "$TG_ARN" \
    | jq '[.TargetHealthDescriptions[] | select(.TargetHealth.State=="healthy")] | length'
  )"

  echo "---- Metric (RequestCountPerTarget Sum / 60s) ----"
  RAW_METRIC="$(
    aws cloudwatch get-metric-statistics \
      --region "$AWS_REGION" \
      --namespace AWS/ApplicationELB \
      --metric-name RequestCountPerTarget \
      --dimensions Name=LoadBalancer,Value="$LB_LABEL" Name=TargetGroup,Value="$TG_LABEL" \
      --start-time "$START" --end-time "$END" --period 60 --statistics Sum
  )"

  echo "HealthyTargets: $HEALTHY_COUNT"
  echo "Scale-In Threshold (per-target RPM): ${DDN_SCALE_IN_REQUEST_COUNT_PER_TARGET}"
  echo -e "Timestamp\t\tperTargetRPM\tperTargetRPS\ttotalRPM\ttotalRPS"

  printf '%s' "$RAW_METRIC" \
  | jq -r --argjson hc "$HEALTHY_COUNT" '
      .Datapoints
      | sort_by(.Timestamp)
      | map({ts:.Timestamp, sum:(.Sum//0)})
      | map({
          ts,
          per_rpm:  ( .sum ),
          per_rps:  ( .sum / 60.0 ),
          total_rpm:( .sum * $hc ),
          total_rps:( (.sum * $hc) / 60.0 )
        })
      | map([.ts, (.per_rpm|tostring), (.per_rps|tostring), (.total_rpm|tostring), (.total_rps|tostring)] | @tsv)
      | .[]
    '

  # 마지막 포인트 임계 비교 (알람과 동일 기준: Sum/60s = per-target RPM)
  LAST_SUM="$(printf '%s' "$RAW_METRIC" | jq -r '.Datapoints | sort_by(.Timestamp) | last?.Sum // 0')"
  awk -v a="$LAST_SUM" -v b="${DDN_SCALE_IN_REQUEST_COUNT_PER_TARGET}" 'BEGIN{
    printf "\nLast datapoint: perTargetRPM=%s (", a;
    if (a < b) { printf "< %s) => BELOW threshold (eligible for Scale-In)\n", b; }
    else       { printf ">= %s) => NOT below threshold\n", b; }
  }'

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
  echo "[INFO] Metric type를 자동 판별하지 못했습니다. (NS='$NS', MN='$MN')"
  echo "[DEBUG] Alarm JSON (trimmed):"
  printf '%s\n' "$ALARM_DESC" | jq '{AlarmName, AlarmArn, Namespace, MetricName, Metrics, Threshold, ComparisonOperator}'
fi

# 5) ECS 서비스 스냅샷
echo "---- ECS Service snapshot ----"
aws ecs describe-services --region "$AWS_REGION" \
  --cluster "$DDN_ECS_CLUSTER" --services "$DDN_ECS_SERVICE" \
| jq -r '.services[0] | {desiredCount,runningCount,pendingCount,events: .events[:5]}'
