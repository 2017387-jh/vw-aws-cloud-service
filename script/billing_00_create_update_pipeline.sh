#!/usr/bin/env bash
set -euo pipefail

# .env 사용
source .env
aws configure set region "${AWS_REGION}"

# helper
j() { aws "$@" --output json; }

echo "[0] Pre-check iam:PassRole for caller → Firehose role"
ROLE_NAME="${BILLING_FIREHOSE_NAME}-role"
CALLER_ARN=$(aws sts get-caller-identity --query Arn --output text)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

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

echo "[1] Ensure S3 bucket: ${BILLING_S3_BUCKET}"
if aws s3api head-bucket --bucket "${BILLING_S3_BUCKET}" 2>/dev/null; then
  aws s3api get-bucket-location --bucket "${BILLING_S3_BUCKET}" || true
else
  aws s3api create-bucket --bucket "${BILLING_S3_BUCKET}" \
    --create-bucket-configuration "LocationConstraint=${AWS_REGION}"
fi

echo "[2] Ensure IAM role for Firehose"
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
        "s3:ListBucket","s3:ListBucketMultipartUploads","s3:PutObject","s3:PutObjectAcl"
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

aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}" >/dev/null || true

aws iam wait role-exists --role-name "$ROLE_NAME" || true
sleep 8
ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)

echo "[3] Create or update Firehose delivery stream → S3 (fast buffering)"
S3CONF=$(cat <<EOF
{"RoleARN":"${ROLE_ARN}",
 "BucketARN":"arn:aws:s3:::${BILLING_S3_BUCKET}",
 "Prefix":"${BILLING_S3_PREFIX}",
 "ErrorOutputPrefix":"${BILLING_S3_ERROR_PREFIX}",
 "BufferingHints":{"IntervalInSeconds":60,"SizeInMBs":1},
 "CompressionFormat":"GZIP",
 "CloudWatchLoggingOptions":{"Enabled":true,"LogGroupName":"/aws/kinesisfirehose/${BILLING_FIREHOSE_NAME}","LogStreamName":"S3Delivery"}}
EOF
)

EXISTS=$(aws firehose list-delivery-streams --query "DeliveryStreamNames[?@=='${BILLING_FIREHOSE_NAME}']" --output text)
if [[ -z "${EXISTS}" ]]; then
  aws firehose create-delivery-stream \
    --delivery-stream-name "${BILLING_FIREHOSE_NAME}" \
    --delivery-stream-type DirectPut \
    --s3-destination-configuration "${S3CONF}" >/dev/null
  echo "[OK] Firehose created: ${BILLING_FIREHOSE_NAME}"
else
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
    --s3-destination-update "${S3CONF}" >/dev/null || true
  echo "[OK] Firehose updated (fast buffering)."
fi

echo "[3.1] Wait until Firehose is ACTIVE"
for i in {1..30}; do
  STATUS=$(aws firehose describe-delivery-stream \
    --delivery-stream-name "${BILLING_FIREHOSE_NAME}" \
    --query 'DeliveryStreamDescription.DeliveryStreamStatus' --output text)
  [[ "$STATUS" == "ACTIVE" ]] && break
  echo "  - status=$STATUS (retry $i)"; sleep 5
done

FIREHOSE_ARN="arn:aws:firehose:${AWS_REGION}:${ACCOUNT_ID}:deliverystream/${BILLING_FIREHOSE_NAME}"

echo "[4] Ensure CloudWatch Log Group for API Gateway access logs"
aws logs describe-log-groups --log-group-name-prefix "${BILLING_LOG_GROUP}" \
  --query 'logGroups[0].logGroupName' --output text | grep -q "${BILLING_LOG_GROUP}" || \
aws logs create-log-group --log-group-name "${BILLING_LOG_GROUP}"
aws logs put-retention-policy --log-group-name "${BILLING_LOG_GROUP}" --retention-in-days 30 >/dev/null || true

echo "[5] Put resource policy (optional)"
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

echo "[6] Create role/policy for Logs → Firehose subscription (with propagation wait)"
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
else
  aws iam update-assume-role-policy --role-name "$LOGS_TO_FH_ROLE" --policy-document "$ASSUME_LOGS_JSON" >/dev/null
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

aws iam wait role-exists --role-name "$LOGS_TO_FH_ROLE" || true
sleep 10
LOGS_TO_FH_ROLE_ARN=$(aws iam get-role --role-name "$LOGS_TO_FH_ROLE" --query 'Role.Arn' --output text)

echo "[6.1] Remove any existing subscription filters (safety)"
EXISTING=$(aws logs describe-subscription-filters \
  --log-group-name "${BILLING_LOG_GROUP}" \
  --query 'subscriptionFilters[].filterName' --output text 2>/dev/null || true)
if [[ -n "${EXISTING}" && "${EXISTING}" != "None" ]]; then
  for F in ${EXISTING}; do
    aws logs delete-subscription-filter \
      --log-group-name "${BILLING_LOG_GROUP}" \
      --filter-name "${F}" >/dev/null 2>&1 || true
  done
fi

echo "[6.2] Create subscription filter with retries"
set +e
for attempt in 1 2 3 4 5; do
  aws logs put-subscription-filter \
    --log-group-name "${BILLING_LOG_GROUP}" \
    --filter-name "ToFirehose" \
    --filter-pattern "" \
    --destination-arn "${FIREHOSE_ARN}" \
    --role-arn "${LOGS_TO_FH_ROLE_ARN}" && ok=1 && break
  echo "[WARN] put-subscription-filter attempt $attempt failed. Retrying in 5s..."
  sleep 5
done
set -e
if [[ "${ok:-0}" != "1" ]]; then
  echo "[ERROR] Failed to create subscription filter after retries"
  exit 1
fi

echo "[7] Enable API Gateway Access Logging to the log group"
API_ID=$(aws apigatewayv2 get-apis --query "Items[?Name=='${DDN_APIGW_NAME}'].ApiId" --output text)
if [[ -z "${API_ID}" || "${API_ID}" == "None" ]]; then
  echo "[WARN] API Gateway not found. Run your API create script first."
  echo "[DONE] Pipeline upsert complete with warnings."
  exit 0
fi

STAGE_NAME="${DDN_APIGW_STAGE_NAME:-\$default}"

ACCESS_JSON=$(jq -n \
  --arg dest "arn:aws:logs:${AWS_REGION}:${ACCOUNT_ID}:log-group:${BILLING_LOG_GROUP}" \
  --arg fmt  "${BILLING_LOG_FORMAT}" \
  '{DestinationArn:$dest, Format:$fmt}')

aws apigatewayv2 update-stage \
  --api-id "${API_ID}" \
  --stage-name "${STAGE_NAME}" \
  --access-log-settings "${ACCESS_JSON}" \
  --auto-deploy >/dev/null

echo "[OK] API access logging → ${BILLING_LOG_GROUP}"
echo "[DONE] Pipeline upsert complete."
