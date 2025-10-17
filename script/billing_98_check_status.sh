#!/usr/bin/env bash
# billing_diag_firehose.sh
# 목적: Firehose ←Role Assume/권한/PassRole 이슈를 단계별 진단하고, 최소 구성 스트림 생성 테스트

set -u

# ---------- 색상/도구 ----------
bold() { printf "\033[1m%s\033[0m\n" "$*"; }
ok()   { printf "✅ %s\n" "$*"; }
warn() { printf "⚠️  %s\n" "$*"; }
err()  { printf "❌ %s\n" "$*"; }
sep()  { printf "\n%s\n" "------------------------------------------------------------"; }

# ---------- .env 로드 ----------
if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  set -a; source .env; set +a
  ok ".env loaded"
else
  warn ".env not found. Using defaults where possible."
fi

AWS_REGION="${AWS_REGION:-ap-northeast-2}"
ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo '')}"

# 과금 파이프라인 변수 (기본값 제공)
BILLING_FIREHOSE_NAME="${BILLING_FIREHOSE_NAME:-ddn-apigw-accesslog-fh}"
BILLING_S3_BUCKET="${BILLING_S3_BUCKET:-ddn-apigw-accesslog-bucket}"
ROLE_NAME="${ROLE_NAME:-${BILLING_FIREHOSE_NAME}-role}"

# ---------- 0) 환경 점검 ----------
sep; bold "0) 환경 점검"
echo "AWS_REGION      : $AWS_REGION"
if [[ -z "$ACCOUNT_ID" || "$ACCOUNT_ID" == "None" ]]; then
  err "계정 ID를 가져오지 못했습니다. 'aws configure set region $AWS_REGION' 및 자격증명 설정을 확인하세요."
  exit 1
fi
echo "ACCOUNT_ID      : $ACCOUNT_ID"
echo "ROLE_NAME       : $ROLE_NAME"
echo "S3 BUCKET       : $BILLING_S3_BUCKET"
echo "FIREHOSE NAME   : $BILLING_FIREHOSE_NAME"

# ---------- 1) Trust Policy 확인 ----------
sep; bold "1) IAM Role 신뢰 정책(Trust Policy) 확인"
if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  err "Role '$ROLE_NAME' 이 존재하지 않습니다. 먼저 생성해 주세요."
  exit 1
fi
aws iam get-role --role-name "$ROLE_NAME" \
  --query 'Role.AssumeRolePolicyDocument' --output json

HAS_TRUST=$(aws iam get-role --role-name "$ROLE_NAME" \
  --query "Role.AssumeRolePolicyDocument.Statement[?Principal.Service=='firehose.amazonaws.com' && Action=='sts:AssumeRole'] | length(@)" \
  --output text)
if [[ "$HAS_TRUST" == "1" || "$HAS_TRUST" == "2" || "$HAS_TRUST" == "3" ]]; then
  ok "Trust policy OK (firehose.amazonaws.com / sts:AssumeRole)"
else
  err "Trust policy에 firehose.amazonaws.com / sts:AssumeRole 항목이 없습니다."
  exit 1
fi

# ---------- 2) Role 권한(Attached Policies) 요약 ----------
sep; bold "2) Role에 부착된 정책 요약"
aws iam list-attached-role-policies --role-name "$ROLE_NAME" --output table
echo
warn "※ 정책 문서에 최소한 다음 액션이 포함되어야 합니다:"
echo "   - S3: s3:PutObject, s3:ListBucket, s3:GetBucketLocation, s3:AbortMultipartUpload, s3:ListBucketMultipartUploads"
echo "   - Logs(선택): logs:CreateLogGroup, logs:CreateLogStream, logs:DescribeLogStreams, logs:PutLogEvents"

# ---------- 3) S3 버킷/정책 확인 ----------
sep; bold "3) S3 버킷 존재/정책 확인"
if aws s3api head-bucket --bucket "$BILLING_S3_BUCKET" 2>/dev/null; then
  ok "Bucket exists: s3://$BILLING_S3_BUCKET"
else
  warn "Bucket이 없어 생성 시도: $BILLING_S3_BUCKET"
  if aws s3api create-bucket --bucket "$BILLING_S3_BUCKET" --create-bucket-configuration "LocationConstraint=$AWS_REGION" >/dev/null 2>&1; then
    ok "Bucket created."
  else
    err "Bucket 생성 실패. 권한 또는 리전 설정을 확인하세요."
    exit 1
  fi
fi

echo
if aws s3api get-bucket-policy --bucket "$BILLING_S3_BUCKET" --query 'Policy' --output text >/dev/null 2>&1; then
  echo "(버킷 정책)"; aws s3api get-bucket-policy --bucket "$BILLING_S3_BUCKET" --query 'Policy' --output text
else
  ok "버킷 정책 없음(기본). 특별한 Deny가 없으면 정상."
fi

# ---------- 4) 실행 주체 iam:PassRole 권한 확인 ----------
sep; bold "4) 현재 실행 주체의 iam:PassRole 권한 확인"
CALLER_ARN=$(aws sts get-caller-identity --query Arn --output text)
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
echo "CALLER_ARN      : $CALLER_ARN"
echo "TARGET ROLE ARN : $ROLE_ARN"

PASS_DECISION=$(aws iam simulate-principal-policy \
  --policy-source-arn "$CALLER_ARN" \
  --action-names iam:PassRole \
  --resource-arns "$ROLE_ARN" \
  --context-entries key=iam:PassedToService,values=firehose.amazonaws.com \
  --query 'EvaluationResults[0].EvalDecision' --output text 2>/dev/null || echo "error")

if [[ "$PASS_DECISION" == "allowed" ]]; then
  ok "iam:PassRole 허용됨(호출자 → Firehose로 Role 전달 가능)"
else
  err "iam:PassRole 거부됨($PASS_DECISION). 관리자에게 위 Role에 대한 PassRole 권한을 요청하세요."
  echo "  (Condition iam:PassedToService=firehose.amazonaws.com 포함 권장)"
  # PassRole이 없어도 이후 테스트는 실패하므로 여기서 종료
  exit 1
fi

# ---------- 5) 최소 구성 Firehose 스트림 생성 테스트 ----------
sep; bold "5) 최소 구성 Firehose 스트림 생성 테스트 (CloudWatch Logs 비활성)"
TEST_STREAM="diag-fh-test-$(date +%s)"
cat > /tmp/s3dest_min.json <<EOF
{
  "RoleARN":"${ROLE_ARN}",
  "BucketARN":"arn:aws:s3:::${BILLING_S3_BUCKET}",
  "Prefix":"diag-test/",
  "BufferingHints":{"IntervalInSeconds":60,"SizeInMBs":5},
  "CompressionFormat":"GZIP",
  "CloudWatchLoggingOptions":{"Enabled":false}
}
EOF

if aws firehose create-delivery-stream \
    --delivery-stream-name "$TEST_STREAM" \
    --delivery-stream-type DirectPut \
    --s3-destination-configuration file:///tmp/s3dest_min.json >/dev/null 2>&1; then
  ok "Firehose 스트림 생성 성공: $TEST_STREAM"
  CREATED=1
else
  CREATED=0
  err "Firehose 스트림 생성 실패. (Trust/PassRole/Role 권한/S3 정책 중 하나 이슈)"
  echo "자세한 원인을 보려면 아래 명령으로 디버그 실행해 보세요:"
  echo "aws firehose create-delivery-stream --delivery-stream-name $TEST_STREAM --delivery-stream-type DirectPut --s3-destination-configuration file:///tmp/s3dest_min.json --debug"
fi

# ---------- 6) (선택) CloudWatch Logs 활성 구성 업데이트 테스트 ----------
if [[ $CREATED -eq 1 ]]; then
  sep; bold "6) (선택) CloudWatch Logs 활성화 업데이트 테스트"
  cat > /tmp/s3dest_logs.json <<EOF
{
  "RoleARN":"${ROLE_ARN}",
  "BucketARN":"arn:aws:s3:::${BILLING_S3_BUCKET}",
  "Prefix":"diag-test/",
  "BufferingHints":{"IntervalInSeconds":60,"SizeInMBs":5},
  "CompressionFormat":"GZIP",
  "CloudWatchLoggingOptions":{"Enabled":true,"LogGroupName":"/aws/firehose/${TEST_STREAM}","LogStreamName":"S3Delivery"}
}
EOF

  VERSION_ID=$(aws firehose describe-delivery-stream --delivery-stream-name "$TEST_STREAM" --query 'DeliveryStreamDescription.VersionId' --output text)
  if aws firehose update-destination \
      --delivery-stream-name "$TEST_STREAM" \
      --current-delivery-stream-version-id "$VERSION_ID" \
      --destination-id "destinationId-000000000001" \
      --s3-destination-update file:///tmp/s3dest_logs.json >/dev/null 2>&1; then
    ok "CloudWatch Logs 활성 업데이트 성공 (Role에 logs 권한 OK)"
  else
    warn "CloudWatch Logs 활성화 업데이트 실패(대개 Role에 logs:* 권한 부족)."
  fi
fi

# ---------- 7) 정리 ----------
if [[ ${CREATED:-0} -eq 1 ]]; then
  sep; bold "정리: 테스트 스트림 삭제"
  aws firehose delete-delivery-stream --delivery-stream-name "$TEST_STREAM" --allow-force-delete >/dev/null 2>&1 && ok "삭제 완료"
fi

sep; bold "진단 완료"
echo "• 5단계에서 실패했다면: Trust/PassRole/Role 권한/S3 정책을 재확인하세요."
echo "• 5단계 성공 & 6단계 실패: Role에 logs 권한(로그 그룹/스트림 생성/쓰기) 추가가 필요합니다."
