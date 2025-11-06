#!/usr/bin/env bash
# check_ddn_alb_rpm.sh
# 사용법:
#   ./check_ddn_alb_rpm.sh               # 기본: 최근 10분
#   ./check_ddn_alb_rpm.sh --minutes 30  # 최근 30분
#   ./check_ddn_alb_rpm.sh --policy      # 스케일링 정책(TargetValue/Statistic)도 같이 표시

set -euo pipefail

MINUTES=10
SHOW_POLICY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --minutes)
      MINUTES="${2:-10}"
      shift 2;;
    --policy)
      SHOW_POLICY=1
      shift;;
    *)
      echo "알 수 없는 옵션: $1" >&2
      exit 1;;
  esac
done

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "필요한 명령어가 없습니다: $1" >&2; exit 1; }
}
require_cmd aws
require_cmd jq
require_cmd sed
require_cmd date

# 1) .env 로드 (모든 변수 export)
if [[ ! -f .env ]]; then
  echo ".env 파일을 현재 디렉토리에서 찾을 수 없습니다." >&2
  exit 1
fi
set -a; source .env; set +a

# 필수 환경변수 체크
: "${AWS_REGION:?AWS_REGION가 .env에 필요합니다}"
: "${DDN_ALB_NAME:?DDN_ALB_NAME가 .env에 필요합니다}"
: "${DDN_TG_FLASK:?DDN_TG_FLASK가 .env에 필요합니다}"
: "${DDN_ECS_CLUSTER:?DDN_ECS_CLUSTER가 .env에 필요합니다}"
: "${DDN_ECS_SERVICE:?DDN_ECS_SERVICE가 .env에 필요합니다}"
: "${DDN_REQUEST_COUNT_PER_TARGET:?DDN_REQUEST_COUNT_PER_TARGET가 .env에 필요합니다}"  # Target(분당)

# 2) ARN 조회
LB_ARN=$(aws elbv2 describe-load-balancers \
  --region "$AWS_REGION" \
  --names "$DDN_ALB_NAME" \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text 2>/dev/null || true)

TG_ARN=$(aws elbv2 describe-target-groups \
  --region "$AWS_REGION" \
  --names "$DDN_TG_FLASK" \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text 2>/dev/null || true)

if [[ -z "${LB_ARN}" || "${LB_ARN}" == "None" ]]; then
  echo "ALB ARN을 가져오지 못했습니다. 이름 확인: DDN_ALB_NAME=${DDN_ALB_NAME}" >&2
  exit 1
fi
if [[ -z "${TG_ARN}" || "${TG_ARN}" == "None" ]]; then
  echo "Target Group ARN을 가져오지 못했습니다. 이름 확인: DDN_TG_FLASK=${DDN_TG_FLASK}" >&2
  exit 1
fi

# 3) CloudWatch 차원 라벨로 변환 (app/... , targetgroup/...)
LB_LABEL=$(echo "$LB_ARN" | sed -E 's|^arn:aws:elasticloadbalancing:[^:]+:[^:]+:loadbalancer/||')
TG_LABEL=$(echo "$TG_ARN" | sed -E 's|^arn:aws:elasticloadbalancing:[^:]+:[^:]+:||')

if [[ -z "$LB_LABEL" || -z "$TG_LABEL" ]]; then
  echo "LB_LABEL/TG_LABEL 추출 실패. ARN을 확인하세요." >&2
  echo "LB_ARN=$LB_ARN" >&2
  echo "TG_ARN=$TG_ARN" >&2
  exit 1
fi

# 4) 시간 범위(UTC). GNU date 기준. (macOS면 coreutils date 필요)
END=$(date -u +%Y-%m-%dT%H:%M:%SZ)
START=$(date -u -d "${MINUTES} minutes ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)
if [[ -z "$START" ]]; then
  # macOS 호환 (gdate가 있을 경우)
  if command -v gdate >/dev/null 2>&1; then
    END=$(gdate -u +%Y-%m-%dT%H:%M:%SZ)
    START=$(gdate -u -d "${MINUTES} minutes ago" +%Y-%m-%dT%H:%M:%SZ)
  else
    echo "date -d 사용이 불가합니다. (macOS라면 coreutils 설치 후 gdate 사용)" >&2
    exit 1
  fi
fi

# 5) 메트릭 조회 (분당 합계 = Sum)
RAW=$(aws cloudwatch get-metric-statistics \
  --region "$AWS_REGION" \
  --namespace AWS/ApplicationELB \
  --metric-name RequestCountPerTarget \
  --dimensions Name=LoadBalancer,Value="$LB_LABEL" Name=TargetGroup,Value="$TG_LABEL" \
  --start-time "$START" --end-time "$END" \
  --period 60 \
  --statistics Sum)

COUNT=$(echo "$RAW" | jq '.Datapoints | length')
if [[ "$COUNT" -eq 0 ]]; then
  echo "최근 ${MINUTES}분 동안 데이터 포인트가 없습니다. (트래픽이 없었을 수 있음)" >&2
  exit 2
fi

echo "=== RequestCountPerTarget (Sum = 분당 합계, 타깃 1개 기준) ==="
echo "리전: ${AWS_REGION}"
echo "ALB:   ${DDN_ALB_NAME}  (Label: ${LB_LABEL})"
echo "TG:    ${DDN_TG_FLASK}  (Label: ${TG_LABEL})"
echo "범위:  ${START}  ~  ${END} (UTC)"
echo

# 표 출력
echo "Timestamp(UTC)                 Sum   RPS(Sum/60)"
echo "--------------------------------  ----  ----------"
echo "$RAW" | jq -r '
  .Datapoints
  | sort_by(.Timestamp)
  | map([.Timestamp, (.Sum // 0), ((.Sum // 0)/60)] | @tsv)
  | .[]
' | awk -F'\t' '{printf "%-32s %4.0f  %10.2f\n", $1, $2, $3}'

# 최신 값 요약 + Target 비교
LATEST=$(echo "$RAW" | jq -r '.Datapoints | sort_by(.Timestamp) | last')
LATEST_TS=$(echo "$LATEST" | jq -r '.Timestamp')
LATEST_SUM=$(echo "$LATEST" | jq -r '.Sum // 0')
LATEST_RPS=$(awk "BEGIN {printf \"%.2f\", (${LATEST_SUM}+0)/60}")

TARGET="${DDN_REQUEST_COUNT_PER_TARGET}"

STATUS="="
cmp=$(awk "BEGIN {print (${LATEST_SUM} > ${TARGET}) ? 1 : ((${LATEST_SUM} < ${TARGET}) ? -1 : 0)}")
if [[ "$cmp" -gt 0 ]]; then STATUS="> (스케일 아웃 경향)"; fi
if [[ "$cmp" -lt 0 ]]; then STATUS="< (스케일 인 경향)"; fi

echo
echo "=== Latest (가장 최근 1분) ==="
printf "Timestamp: %s (UTC)\n" "$LATEST_TS"
printf "Sum:       %.0f (분당/타깃)\n" "$LATEST_SUM"
printf "RPS:       %s (참고용)\n" "$LATEST_RPS"
printf "Target:    %s (분당/타깃)\n" "$TARGET"
printf "비교:      Sum %s Target\n" "$STATUS"

# 6) (옵션) 스케일링 정책 확인
if [[ "$SHOW_POLICY" -eq 1 ]]; then
  echo
  echo "=== Scaling Policy (TargetTracking) ==="
  aws application-autoscaling describe-scaling-policies \
    --region "$AWS_REGION" \
    --service-namespace ecs \
    --resource-id "service/${DDN_ECS_CLUSTER}/${DDN_ECS_SERVICE}" \
  | jq -r '
      .ScalingPolicies[]
      | select(.PolicyType=="TargetTrackingScaling")
      | {
          PolicyName,
          TargetValue: .TargetTrackingScalingPolicyConfiguration.TargetValue,
          CustomizedMetric: .TargetTrackingScalingPolicyConfiguration.CustomizedMetricSpecification.MetricName,
          Namespace: .TargetTrackingScalingPolicyConfiguration.CustomizedMetricSpecification.Namespace,
          Dimensions: .TargetTrackingScalingPolicyConfiguration.CustomizedMetricSpecification.Dimensions,
          Statistic: (
            .TargetTrackingScalingPolicyConfiguration.CustomizedMetricSpecification.Statistic
            // (
              .TargetTrackingScalingPolicyConfiguration.CustomizedMetricSpecification.Metrics[]?
              | select(.MetricStat?) | .MetricStat.Stat
            )
          ),
          Period: (
            .TargetTrackingScalingPolicyConfiguration.CustomizedMetricSpecification.Metrics[]?
            | select(.MetricStat?) | .MetricStat.Period
          ),
          ScaleInCooldown: .TargetTrackingScalingPolicyConfiguration.ScaleInCooldown,
          ScaleOutCooldown: .TargetTrackingScalingPolicyConfiguration.ScaleOutCooldown
        }'
fi
