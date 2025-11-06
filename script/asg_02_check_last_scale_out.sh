#!/usr/bin/env bash
set -euo pipefail
set -a; source .env; set +a

# --- 1) 마지막 "증가" 활동(Scale OUT) 찾기
RAW_ACTS=$(aws application-autoscaling describe-scaling-activities \
  --region "$AWS_REGION" --service-namespace ecs \
  --resource-id service/$DDN_ECS_CLUSTER/$DDN_ECS_SERVICE \
  --max-results 20)

# 최근 성공 활동에서 "monitor alarm ... triggered policy ..."가 있고
# 메시지의 desired count가 직전보다 증가한 케이스를 골라본다.
# (증가/감소 구분이 애매하면 일단 "ScaleOut" 이름/정책명으로 판단 보정)
LAST_OUT_JSON=$(
  echo "$RAW_ACTS" | jq -c '
    .ScalingActivities
    | map(select(.StatusCode=="Successful"))
    | sort_by(.StartTime)
    | reduce .[] as $a (
        {prevDesired:null, lastOut:null};
        . as $acc
        | ($a.StatusMessage | capture("desired count to (?<d>[0-9]+)"; "i").d | tonumber) as $d
        | ($a.Cause // "") as $cause
        | ($acc.prevDesired) as $p
        | ($p != null and $d > $p
           or ($cause|test("ScaleOut";"i"))
           or ($cause|test("stepscale-out";"i"))
          )
          as $is_out
        | ($a + {desired:$d, is_out:$is_out, prev:$p}) as $curr
        | {
            prevDesired: $d,
            lastOut: (if $is_out then $curr else .lastOut end)
          }
    ).lastOut
  '
)

if [[ -z "${LAST_OUT_JSON}" || "${LAST_OUT_JSON}" == "null" ]]; then
  echo "[INFO] 최근 Scale OUT 성공 활동을 찾지 못했습니다."
  exit 0
fi

START_TS=$(echo "$LAST_OUT_JSON" | jq -r '.StartTime')
CAUSE=$(echo "$LAST_OUT_JSON" | jq -r '.Cause')
DESIRED=$(echo "$LAST_OUT_JSON" | jq -r '.desired')
echo "== Last Scale OUT =="
echo "StartTime : $START_TS"
echo "Desired   : $DESIRED"
echo "Cause     : $CAUSE"

# --- 2) Cause에서 알람 이름/정책 추출
ALARM_NAME=$(echo "$CAUSE" | sed -n 's/.*monitor alarm \(.*\) in state.*/\1/p')
POLICY_NAME=$(echo "$CAUSE" | sed -n 's/.*triggered policy \(.*\)$/\1/p')
echo "AlarmName : ${ALARM_NAME:-N/A}"
echo "Policy    : ${POLICY_NAME:-N/A}"

# --- 3) 알람 히스토리 (상태 변화 시각)
if [[ -n "${ALARM_NAME:-}" ]]; then
  echo "---- Alarm History (state updates) ----"
  aws cloudwatch describe-alarm-history \
    --region "$AWS_REGION" \
    --alarm-name "$ALARM_NAME" \
    --history-item-type StateUpdate \
    --max-items 10 \
  | jq -r '.AlarmHistoryItems[] | [.Timestamp, .HistorySummary] | @tsv'
fi

# --- 4) 어떤 지표가 임계를 넘었는지(주로 ALB Sum=분당합계) 보여주기
# ALB/TG 라벨 계산
LB_ARN=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" --names "$DDN_ALB_NAME" --query 'LoadBalancers[0].LoadBalancerArn' --output text)
TG_ARN=$(aws elbv2 describe-target-groups   --region "$AWS_REGION" --names "$DDN_TG_FLASK"  --query 'TargetGroups[0].TargetGroupArn'  --output text)
LB_LABEL=$(echo "$LB_ARN" | sed -E 's|^arn:aws:elasticloadbalancing:[^:]+:[^:]+:loadbalancer/||')
TG_LABEL=$(echo "$TG_ARN" | sed -E 's|^arn:aws:elasticloadbalancing:[^:]+:[^:]+:||')

# 진단 창: 활동시각 주변 ±6분
END=$(date -u -d "${START_TS} + 2 minutes" +%Y-%m-%dT%H:%M:%SZ)
START=$(date -u -d "${START_TS} - 8 minutes" +%Y-%m-%dT%H:%M:%SZ)

echo "---- Metric (RequestCountPerTarget Sum per 60s) ----"
echo "Window: $START ~ $END (UTC)"
aws cloudwatch get-metric-statistics \
  --region "$AWS_REGION" \
  --namespace AWS/ApplicationELB \
  --metric-name RequestCountPerTarget \
  --dimensions Name=LoadBalancer,Value="$LB_LABEL" Name=TargetGroup,Value="$TG_LABEL" \
  --start-time "$START" --end-time "$END" --period 60 --statistics Sum \
| jq -r '.Datapoints | sort_by(.Timestamp)
         | map("\(.Timestamp)  Sum=\(.Sum)") | .[]'

# --- 5) 서비스 카운트/이벤트 스냅샷
echo "---- ECS Service snapshot ----"
aws ecs describe-services --region "$AWS_REGION" \
  --cluster "$DDN_ECS_CLUSTER" --services "$DDN_ECS_SERVICE" \
| jq -r '.services[0] | {desiredCount,runningCount,pendingCount,events: .events[:5]}'
echo "[✅ DONE] Last Scale OUT check completed."