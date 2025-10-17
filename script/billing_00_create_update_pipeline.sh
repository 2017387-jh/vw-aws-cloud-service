#!/usr/bin/env bash
set -euo pipefail
source .env
aws configure set region "${AWS_REGION}"

# --- Helper ---
j() { aws "$@" --output json; }  # quick json alias

echo "[0] Pre-check iam:PassRole for caller → Firehose role"
ROLE_NAME="${BILLING_FIREHOSE_NAME}-role"

CALLER_ARN=$(aws sts get-caller-identity --query Arn --output text)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

# 디버그 출력(문제 시 주석 풀고 확인)
# set -x
# echo "DEBUG CALLER_ARN=$CALLER_ARN"
# echo "DEBUG ROLE_ARN=$ROLE_ARN"

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
aws s3api head-bucket --bucket "${BILLING_S3_BUCKET}" 2>/dev/null || \
aws s3api create-bucket --bucket "${BILLING_S3_BUCKET}" --create-bucket-configuration LocationConstraint="${AWS_REGION}"

echo "[2] Create/ensure IAM role for Firehose"
POLICY_NAME="${BILLING_FIREHOSE_NAME}-policy"
ASSUME_JSON='{
 "Version":"2012-10-17",
 "Statement":[{"Effect":"Allow","Principal":{"Service":"firehose.amazonaws.com"},"Action":"sts:AssumeRole"}]
}'
aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1 || \
aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "$ASSUME_JSON" >/dev/null

# 최소 권한: S3 + Logs (KMS 미사용 가정)
read -r -d '' POLICY_JSON <<EOF
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
   ]
 ]
}
EOF

aws iam get-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}" >/dev/null 2>&1 || \
aws iam create-policy --policy-name "${POLICY_NAME}" --policy-document "$POLICY_JSON" >/dev/null || true
aws iam attach-role-policy --role-name "$ROLE_NAME" \
  --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}" >/dev/null || true

# 전파 대기 (짧게)
sleep 5
ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)

echo "[3] Create/ensure Firehose delivery stream → S3"
# CloudWatch Logs 옵션은 일단 꺼두고 생성 → 나중에 업데이트에서 켬(권한 원인 분리)
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
  # DestinationId 조회
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
FIREHOSE_ARN="arn:aws:firehose:${AWS_REGION}:${ACCOUNT_ID}:deliverystream/${BILLING_FIREHOSE_NAME}"

# 이제 CloudWatch Logs 옵션을 켬 (권한 문제시 여기서만 실패하게)
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

echo "[4] Create/ensure CloudWatch Log Group for API Gateway access logs"
aws logs describe-log-groups --log-group-name-prefix "${BILLING_LOG_GROUP}" \
  --query 'logGroups[0].logGroupName' --output text | grep -q "${BILLING_LOG_GROUP}" || \
aws logs create-log-group --log-group-name "${BILLING_LOG_GROUP}"
aws logs put-retention-policy --log-group-name "${BILLING_LOG_GROUP}" --retention-in-days 30 >/dev/null || true

echo "[5] Put resource policy (CloudWatch Logs → Firehose subscription)"
# 조건을 좁히면 실패 케이스가 많아질 수 있으니 처음엔 단순 허용
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

echo "[6] Subscribe the log group to Firehose"
aws logs put-subscription-filter \
  --log-group-name "${BILLING_LOG_GROUP}" \
  --filter-name "ToFirehose" \
  --filter-pattern "" \
  --destination-arn "${FIREHOSE_ARN}" >/dev/null || true

echo "[7] Enable API Gateway Access Logging to the log group (HTTP API)"
API_ID=$(aws apigatewayv2 get-apis --query "Items[?Name=='${DDN_APIGW_NAME}'].ApiId" --output text)
if [[ -z "${API_ID}" || "${API_ID}" == "None" ]]; then
  echo "[WARN] API Gateway not found. Run your API create script first."
  exit 0
fi

# 리터럴 $default 처리
STAGE_NAME="${DDN_APIGW_STAGE_NAME:-\$default}"

aws apigatewayv2 update-stage \
  --api-id "${API_ID}" \
  --stage-name "${STAGE_NAME}" \
  --access-log-settings "DestinationArn=arn:aws:logs:${AWS_REGION}:${ACCOUNT_ID}:log-group:${BILLING_LOG_GROUP},Format=${BILLING_LOG_FORMAT}" \
  --auto-deploy >/dev/null

echo "[OK] API access logging → ${BILLING_LOG_GROUP}"
echo "[DONE] Billing pipeline upsert complete."
