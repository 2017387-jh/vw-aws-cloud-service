#!/usr/bin/env bash
set -euo pipefail
source .env
aws configure set region "${AWS_REGION}"

echo "[1] Create/ensure S3 bucket: ${BILLING_S3_BUCKET}"
aws s3api head-bucket --bucket "${BILLING_S3_BUCKET}" 2>/dev/null || \
aws s3api create-bucket --bucket "${BILLING_S3_BUCKET}" --create-bucket-configuration LocationConstraint="${AWS_REGION}"

echo "[2] Create/ensure IAM role for Firehose"
ROLE_NAME="${BILLING_FIREHOSE_NAME}-role"
POLICY_NAME="${BILLING_FIREHOSE_NAME}-policy"
ASSUME_JSON=$(cat <<EOF
{
 "Version":"2012-10-17",
 "Statement":[{"Effect":"Allow","Principal":{"Service":"firehose.amazonaws.com"},"Action":"sts:AssumeRole"}]
}
EOF
)
aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1 || aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "$ASSUME_JSON" >/dev/null

POLICY_JSON=$(cat <<EOF
{
 "Version":"2012-10-17",
 "Statement":[
   {"Effect":"Allow","Action":["s3:AbortMultipartUpload","s3:GetBucketLocation","s3:GetObject","s3:ListBucket","s3:ListBucketMultipartUploads","s3:PutObject"],"Resource":["arn:aws:s3:::${BILLING_S3_BUCKET}","arn:aws:s3:::${BILLING_S3_BUCKET}/*"]},
   {"Effect":"Allow","Action":["logs:PutLogEvents"],"Resource":"*"},
   {"Effect":"Allow","Action":["kms:Encrypt","kms:Decrypt","kms:GenerateDataKey","kms:DescribeKey"],"Resource":"*"}
 ]
}
EOF
)
aws iam get-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}" >/dev/null 2>&1 || \
aws iam create-policy --policy-name "${POLICY_NAME}" --policy-document "$POLICY_JSON" >/dev/null || true
aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}" >/dev/null || true

ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)

echo "[3] Create/ensure Firehose delivery stream → S3"
S3CONF=$(cat <<EOF
{"RoleARN":"${ROLE_ARN}",
 "BucketARN":"arn:aws:s3:::${BILLING_S3_BUCKET}",
 "Prefix":"${BILLING_S3_PREFIX}",
 "ErrorOutputPrefix":"${BILLING_S3_ERROR_PREFIX}",
 "BufferingHints":{"IntervalInSeconds":300,"SizeInMBs":128},
 "CompressionFormat":"GZIP",
 "CloudWatchLoggingOptions":{"Enabled":true,"LogGroupName":"/aws/firehose/${BILLING_FIREHOSE_NAME}","LogStreamName":"S3Delivery"}}
EOF
)
EXISTS=$(aws firehose list-delivery-streams --query "DeliveryStreamNames[?@=='${BILLING_FIREHOSE_NAME}']" --output text)
if [[ -z "${EXISTS}" ]]; then
  aws firehose create-delivery-stream --delivery-stream-name "${BILLING_FIREHOSE_NAME}" \
    --delivery-stream-type DirectPut \
    --s3-destination-configuration "${S3CONF}" >/dev/null
else
  aws firehose update-destination --delivery-stream-name "${BILLING_FIREHOSE_NAME}" \
    --current-delivery-stream-version-id $(aws firehose describe-delivery-stream --delivery-stream-name "${BILLING_FIREHOSE_NAME}" --query 'DeliveryStreamDescription.VersionId' --output text) \
    --destination-id "destinationId-000000000001" \
    --s3-destination-update "${S3CONF}" >/dev/null || true
fi
FIREHOSE_ARN="arn:aws:firehose:${AWS_REGION}:${ACCOUNT_ID}:deliverystream/${BILLING_FIREHOSE_NAME}"
echo "[OK] Firehose: ${BILLING_FIREHOSE_NAME}"

echo "[4] Create/ensure CloudWatch Log Group for API Gateway access logs"
aws logs describe-log-groups --log-group-name-prefix "${BILLING_LOG_GROUP}" --query 'logGroups[0].logGroupName' --output text | grep -q "${BILLING_LOG_GROUP}" || \
aws logs create-log-group --log-group-name "${BILLING_LOG_GROUP}"
aws logs put-retention-policy --log-group-name "${BILLING_LOG_GROUP}" --retention-in-days 30 >/dev/null || true

echo "[5] Grant Firehose subscription permission on the log group"
aws logs put-resource-policy \
  --policy-name "FirehoseSubscriptionPolicy" \
  --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"logs.${AWS_REGION}.amazonaws.com\"},\"Action\":\"logs:PutSubscriptionFilter\",\"Resource\":\"arn:aws:logs:${AWS_REGION}:${ACCOUNT_ID}:log-group:${BILLING_LOG_GROUP}:*\",\"Condition\":{\"StringEquals\":{\"aws:SourceArn\":\"${FIREHOSE_ARN}\"}}}]}" >/dev/null || true

echo "[6] Subscribe the log group to Firehose"
aws logs put-subscription-filter \
  --log-group-name "${BILLING_LOG_GROUP}" \
  --filter-name "ToFirehose" \
  --filter-pattern "" \
  --destination-arn "${FIREHOSE_ARN}" >/dev/null || true

echo "[7] Enable API Gateway Access Logging to the log group (HTTP API)"
API_ID=$(aws apigatewayv2 get-apis --query "Items[?Name=='${DDN_APIGW_NAME}'].ApiId" --output text)
if [[ -z "${API_ID}" || "${API_ID}" == "None" ]]; then
  echo "[WARN] API Gateway not found. Run your API create script first."; exit 0
fi
STAGE_NAME="${DDN_APIGW_STAGE_NAME:-$default}"
aws apigatewayv2 update-stage \
  --api-id "${API_ID}" \
  --stage-name "${STAGE_NAME}" \
  --access-log-settings "DestinationArn=arn:aws:logs:${AWS_REGION}:${ACCOUNT_ID}:log-group:${BILLING_LOG_GROUP},Format=${BILLING_LOG_FORMAT}" \
  --auto-deploy >/dev/null
echo "[OK] API access logging → ${BILLING_LOG_GROUP}"
