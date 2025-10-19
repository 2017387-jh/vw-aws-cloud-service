#!/usr/bin/env bash
set -euo pipefail

# --- Load env and set region ---
source .env
aws configure set region "${AWS_REGION}"

# --- Helpers ---
j() { aws "$@" --output json; }  # quick json alias

echo "[0] Pre-check iam:PassRole for caller → Firehose role"
ROLE_NAME="${BILLING_FIREHOSE_NAME}-role"
CALLER_ARN=$(aws sts get-caller-identity --query Arn --output text)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

# Correct parameter names for --context-entries
PASS_DECISION=$(aws iam simulate-principal-policy \
  --policy-source-arn "$CALLER_ARN" \
  --action-names iam:PassRole \
  --resource-arns "$ROLE_ARN" \
  --context-entries ContextKeyName=iam:PassedToService,ContextKeyValues=firehose.amazonaws.com,ContextKeyType=string \
  --query 'EvaluationResults[0].EvalDecision' --output text 2>/dev/null || echo "error")

if [[ "$PASS_DECISION" != "allowed" ]]; then
  echo "[ERROR] iam:PassRole denied for caller: $CALLER_ARN → $ROLE_ARN"
  echo "        Ask admin to allow iam:PassRole with condition iam:PassedToService=firehose.amazonaws.com"
  exit 1
fi
echo "[OK] PassRole allowed."

echo "[1] Create/ensure S3 bucket: ${BILLING_S3_BUCKET}"
# head-bucket 성공시 리전 확인만 출력, 없으면 생성
if aws s3api head-bucket --bucket "${BILLING_S3_BUCKET}" 2>/dev/null; then
  aws s3api get-bucket-location --bucket "${BILLING_S3_BUCKET}" || true
else
  aws s3api create-bucket --bucket "${BILLING_S3_BUCKET}" \
    --create-bucket-configuration "LocationConstraint=${AWS_REGION}"
fi

echo "[2] Create/ensure IAM role for Firehose"
POLICY_NAME="${BILLING_FIREHOSE_NAME}-policy"

ASSUME_JSON=$(cat <<'EOF'
{
  "Version":"2012-10-17",
  "Statement":[
    {"Effect":"Allow","Principal":{"Service":"firehose.amazonaws.com"},"Action":"sts:AssumeRole"}
  ]
}
EOF
)

# Create role if not exists, then attach minimal S3+Logs policy
if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "$ASSUME_JSON" >/dev/null
fi

POLICY_JSON=$(cat <<EOF
{
  "Version":"2012-10-17",
  "Statement":[
    {
      "Effect":"Allow",
      "Action":[
        "s3:AbortMultipartUpload","s3:GetBucketLocation","s3:GetObject",
        "s3:ListBucket","s3:ListBucketMultipartUploads","s3:PutObject"
      ],
      "Resource":[
        "arn:aws:s3:::${BILLING_S3_BUCKET}",
        "arn:aws:s3:::${BILLING_S3_BUCKET}/*"
      ]
    },
    {
      "Effect":"Allow",
      "Action":[
        "logs:CreateLogGroup","logs:CreateLogStream",
        "logs:DescribeLogStreams","logs:PutLogEvents"
      ],
      "Resource":"*"
    }
  ]
}
EOF
)

if ! aws iam get-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}" >/dev/null 2>&1; then
  aws iam create-policy --policy-name "${POLICY_NAME}" --policy-document "$POLICY_JSON" >/dev/null || true
fi
aws iam attach-role-policy --role-name "$ROLE_NAME" \
  --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}" >/dev/null || true

# small propagation wait
aws iam wait role-exists --role-name "$ROLE_NAME" || true
sleep 8
ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)

echo "[3] Create/ensure Firehose delivery stream → S3"
# Create with CloudWatchLoggingOptions disabled first
S3CONF_MIN=$(cat <<EOF
{"RoleARN":"${ROLE_ARN}",
 "BucketARN":"arn:aws:s3:::${BILLING_S3_BUCKET}",
 "Prefix":"${BILLING_S3_PREFIX}",
 "ErrorOutputPrefix":"${BILLING_S3_ERROR_PREFIX}",
 "BufferingHints":{"IntervalInSeconds":300,"SizeInMBs":128},
 "CompressionFormat":"GZIP",
 "CloudWatchLoggingOptions":{"Enabled":false}}
EOF
)

EXISTS=$(aws firehose list-delivery-streams --query "DeliveryStreamNames[?@=='${BILLING_FIREHOSE_NAME}']" --output text)
if [[ -z "${EXISTS}" ]]; then
  aws firehose create-delivery-stream \
    --delivery-stream-name "${BILLING_FIREHOSE_NAME}" \
    --delivery-stream-type DirectPut \
    --s3-destination-configuration "${S3CONF_MIN}" >/dev/null
  echo "[OK] Firehose created: ${BILLING_FIREHOSE_NAME}"
else
  # ensure minimal config on existing destination
  DEST_ID=$(aws firehose describe-delivery-stream \
    --delivery-stream-name "${BILLING_FIREHOSE_NAME}" \
    --query 'DeliveryStreamDescription.Destinations[0].DestinationId' --output text)
  VER_ID=$(aws firehose describe-delivery-stream \
    --delivery-stream-name "${BILLING_FIREHOSE_NAME}" \
    --query 'DeliveryStreamDescription.VersionId' --output text)
  aws firehose update-destination \
    --delivery-stream-name "${BILLING_FIREHOSE_NAME}" \
    --current-delivery-stream-version-id "${VER_ID}" \
    --destination-id "${DEST_ID}" \
    --s3-destination-update "${S3CONF_MIN}" >/dev/null || true
  echo "[OK] Firehose updated (minimal)."
fi

# Wait until stream ACTIVE before enabling CloudWatch logging
echo "[3.1] Wait until Firehose is ACTIVE"
for i in {1..30}; do
  STATUS=$(aws firehose describe-delivery-stream \
    --delivery-stream-name "${BILLING_FIREHOSE_NAME}" \
    --query 'DeliveryStreamDescription.DeliveryStreamStatus' --output text)
  [[ "$STATUS" == "ACTIVE" ]] && break
  echo "  - status=$STATUS (retry $i)"; sleep 5
done

# Enable logging after ACTIVE
S3CONF_LOGS=$(cat <<EOF
{"RoleARN":"${ROLE_ARN}",
 "BucketARN":"arn:aws:s3:::${BILLING_S3_BUCKET}",
 "Prefix":"${BILLING_S3_PREFIX}",
 "ErrorOutputPrefix":"${BILLING_S3_ERROR_PREFIX}",
 "BufferingHints":{"IntervalInSeconds":300,"SizeInMBs":128},
 "CompressionFormat":"GZIP",
 "CloudWatchLoggingOptions":{"Enabled":true,"LogGroupName":"/aws/firehose/${BILLING_FIREHOSE_NAME}","LogStreamName":"S3Delivery"}}
EOF
)

DEST_ID=$(aws firehose describe-delivery-stream \
  --delivery-stream-name "${BILLING_FIREHOSE_NAME}" \
  --query 'DeliveryStreamDescription.Destinations[0].DestinationId' --output text)
VER_ID=$(aws firehose describe-delivery-stream \
  --delivery-stream-name "${BILLING_FIREHOSE_NAME}" \
  --query 'DeliveryStreamDescription.VersionId' --output text)

aws firehose update-destination \
  --delivery-stream-name "${BILLING_FIREHOSE_NAME}" \
  --current-delivery-stream-version-id "${VER_ID}" \
  --destination-id "${DEST_ID}" \
  --s3-destination-update "${S3CONF_LOGS}" >/dev/null || echo "[WARN] Firehose CloudWatch Logs 활성화 실패(권한 필요)."

FIREHOSE_ARN="arn:aws:firehose:${AWS_REGION}:${ACCOUNT_ID}:deliverystream/${BILLING_FIREHOSE_NAME}"

echo "[4] Create/ensure CloudWatch Log Group for API Gateway access logs"
aws logs describe-log-groups --log-group-name-prefix "${BILLING_LOG_GROUP}" \
  --query 'logGroups[0].logGroupName' --output text | grep -q "${BILLING_LOG_GROUP}" || \
aws logs create-log-group --log-group-name "${BILLING_LOG_GROUP}"
aws logs put-retention-policy --log-group-name "${BILLING_LOG_GROUP}" --retention-in-days 30 >/dev/null || true

echo "[5] Put resource policy (CloudWatch Logs → Firehose subscription) [optional]"
POLICY_DOC=$(cat <<EOF
{
  "Version":"2012-10-17",
  "Statement":[
    {
      "Sid":"AllowLogsToPutSubFilterToFirehose",
      "Effect":"Allow",
      "Principal":{"Service":"logs.${AWS_REGION}.amazonaws.com"},
      "Action":"logs:PutSubscriptionFilter",
      "Resource":"arn:aws:logs:${AWS_REGION}:${ACCOUNT_ID}:log-group:${BILLING_LOG_GROUP}:*"
    }
  ]
}
EOF
)
aws logs put-resource-policy --policy-name "FirehoseSubscriptionPolicy" \
  --policy-document "${POLICY_DOC}" >/dev/null || true

echo "[6] Subscribe the log group to Firehose (with role-arn)"
# Create role for CloudWatch Logs → Firehose subscription
LOGS_TO_FH_ROLE="${BILLING_FIREHOSE_NAME}-logs-to-fh-role"
ASSUME_LOGS_JSON=$(cat <<EOF
{
 "Version":"2012-10-17",
 "Statement":[{"Effect":"Allow","Principal":{"Service":"logs.${AWS_REGION}.amazonaws.com"},"Action":"sts:AssumeRole"}]
}
EOF
)
if ! aws iam get-role --role-name "$LOGS_TO_FH_ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$LOGS_TO_FH_ROLE" --assume-role-policy-document "$ASSUME_LOGS_JSON" >/dev/null
fi

LOGS_TO_FH_POLICY="${BILLING_FIREHOSE_NAME}-logs-to-fh-policy"
LOGS_TO_FH_POLICY_DOC=$(cat <<EOF
{
 "Version":"2012-10-17",
 "Statement":[
   {"Effect":"Allow","Action":["firehose:PutRecord","firehose:PutRecordBatch"],"Resource":"${FIREHOSE_ARN}"}
 ]
}
EOF
)
if ! aws iam get-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${LOGS_TO_FH_POLICY}" >/dev/null 2>&1; then
  aws iam create-policy --policy-name "${LOGS_TO_FH_POLICY}" --policy-document "$LOGS_TO_FH_POLICY_DOC" >/dev/null || true
fi
aws iam attach-role-policy --role-name "$LOGS_TO_FH_ROLE" \
  --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${LOGS_TO_FH_POLICY}" >/dev/null || true
LOGS_TO_FH_ROLE_ARN=$(aws iam get-role --role-name "$LOGS_TO_FH_ROLE" --query 'Role.Arn' --output text)

# put-subscription-filter with role arn
aws logs put-subscription-filter \
  --log-group-name "${BILLING_LOG_GROUP}" \
  --filter-name "ToFirehose" \
  --filter-pattern "" \
  --destination-arn "${FIREHOSE_ARN}" \
  --role-arn "${LOGS_TO_FH_ROLE_ARN}" >/dev/null || true

echo "[7] Enable API Gateway Access Logging to the log group (HTTP API)"
API_ID=$(aws apigatewayv2 get-apis --query "Items[?Name=='${DDN_APIGW_NAME}'].ApiId" --output text)
if [[ -z "${API_ID}" || "${API_ID}" == "None" ]]; then
  echo "[WARN] API Gateway not found. Run your API create script first."
  echo "[DONE] Billing pipeline upsert complete with warnings."
  exit 0
fi

# Handle literal $default
STAGE_NAME="${DDN_APIGW_STAGE_NAME:-\$default}"

# Format string may contain quotes and $context. Escape $ to avoid shell/cli expansion.
FMT="${BILLING_LOG_FORMAT}"
# If .env wrapped with single quotes, strip them
if [[ "${FMT}" == \'*\' ]]; then FMT="${FMT:1:-1}"; fi

# 1) $context 가 쉘에서 풀리지 않도록 escape
FMT_ESC=$(printf '%s' "$BILLING_LOG_FORMAT" \
  | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\$/\\$/g')

# 2) 구조형 인자를 JSON으로 전달
ACCESS_JSON="{\"DestinationArn\":\"arn:aws:logs:${AWS_REGION}:${ACCOUNT_ID}:log-group:${BILLING_LOG_GROUP}\",\"Format\":\"${FMT_ESC}\"}"

# 3) stage 이름이 $default 라면 리터럴로 넘기기
STAGE_NAME="${DDN_APIGW_STAGE_NAME:-\$default}"

aws apigatewayv2 update-stage \
  --api-id "${API_ID}" \
  --stage-name "${STAGE_NAME}" \
  --access-log-settings "${ACCESS_JSON}" \
  --auto-deploy >/dev/null

echo "[OK] API access logging → ${BILLING_LOG_GROUP}"
echo "[DONE] Billing pipeline upsert complete."
