#!/usr/bin/env bash
set -euo pipefail

# 0) env
set -a; source .env; set +a

# 1) 최근 활동에서 "ScaleOut 관련"인 마지막 1건을 집자
RAW_ACTS="$(aws application-autoscaling describe-scaling-activities \
  --region "$AWS_REGION" --service-namespace ecs \
  --resource-id service/$DDN_ECS_CLUSTER/$DDN_ECS_SERVICE \
  --max-results 50)"

LAST_OUT_JSON="$(
  printf '%s' "$RAW_ACTS" | jq -c '
    .ScalingActivities
    | map(select(.StatusCode=="Successful"))
    | sort_by(.StartTime)
    | map(. + {
        desired: ((.StatusMessage|capture("desired count to (?<d>[0-9]+)"; "i").d // "NaN") | tonumber?),
        is_out:   (.Cause|test("ScaleOut|stepscale-out|ScaleOut-ReqPerTarget|gt-[0-9]+-1m"; "i"))
      })
    | reverse
    | (.[] | select(.is_out==true)) // empty
    | . // 첫 번째 하나만
    | first
  '
)"

if [[ -z "${LAST_OUT_JSON}" || "${LAST_OUT_JSON}" == "null" ]]; then
  echo "[INFO] 최근 Scale OUT 성공 활동을 찾지 못했습니다."
  exit 0
fi

START_TS="$(printf '%s' "$LAST_OUT_JSON" | jq -r '.StartTime')"
CAUSE="$(printf '%s' "$LAST_OUT_JSON" | jq -r '.Cause')"
DESIRED="$(printf '%s' "$LAST_OUT_JSON" | jq -r '.desired')"

echo "== Last Scale OUT =="
echo "StartTime : $START_TS"
echo "Desired   : ${DESIRED:-N/A}"
echo "Cause     : $CAUSE"

# 2) Cause에서 알람/정책 이름 뽑기
ALARM_NAME="$(printf '%s' "$CAUSE" | sed -n 's/.*monitor alarm \(.*\) in state.*/\1/p')"
POLICY_NAME="$(printf '%s' "$CAUSE" | sed -n 's/.*triggered policy \(.*\)$/\1/p')"
echo "AlarmName : ${ALARM_NAME:-N/A}"
echo "Policy    : ${POLICY_NAME:-N/A}"

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

# 4) 그 시각 전후의 지표(분당 합계) 보기
LB_ARN="$(aws elbv2 describe-load-balancers --region "$AWS_REGION" --names "$DDN_ALB_NAME" --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
TG_ARN="$(aws elbv2 describe-target-groups   --region "$AWS_REGION" --names "$DDN_TG_FLASK"  --query 'TargetGroups[0].TargetGroupArn'  --output text)"
LB_LABEL="$(printf '%s' "$LB_ARN" | sed -E 's|^arn:aws:elasticloadbalancing:[^:]+:[^:]+:loadbalancer/||')"
TG_LABEL="$(printf '%s' "$TG_ARN" | sed -E 's|^arn:aws:elasticloadbalancing:[^:]+:[^:]+:||')"

END="$(date -u -d "${START_TS} + 2 minutes" +%Y-%m-%dT%H:%M:%SZ)"
START="$(date -u -d "${START_TS} - 8 minutes" +%Y-%m-%dT%H:%M:%SZ)"

echo "---- Metric (RequestCountPerTarget Sum / 60s) ----"
echo "Window: $START ~ $END (UTC)"
aws cloudwatch get-metric-statistics \
  --region "$AWS_REGION" \
  --namespace AWS/ApplicationELB \
  --metric-name RequestCountPerTarget \
  --dimensions Name=LoadBalancer,Value="$LB_LABEL" Name=TargetGroup,Value="$TG_LABEL" \
  --start-time "$START" --end-time "$END" --period 60 --statistics Sum \
| jq -r '.Datapoints | sort_by(.Timestamp) | map("\(.Timestamp)  Sum=\(.Sum)") | .[]'

# 5) ECS 서비스 스냅샷
echo "---- ECS Service snapshot ----"
aws ecs describe-services --region "$AWS_REGION" \
  --cluster "$DDN_ECS_CLUSTER" --services "$DDN_ECS_SERVICE" \
| jq -r '.services[0] | {desiredCount,runningCount,pendingCount,events: .events[:5]}'
