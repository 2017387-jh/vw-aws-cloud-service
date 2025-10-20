#!/usr/bin/env bash
set -euo pipefail

# .env 사용
source .env
aws configure set region "${AWS_REGION}"

# 공통 변수
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
API_ID=$(aws apigatewayv2 get-apis --query "Items[?Name=='${DDN_APIGW_NAME}'].ApiId" --output text || true)
STAGE_NAME="${DDN_APIGW_STAGE_NAME:-\$default}"  # 리터럴 유지

FIREHOSE_ROLE="${BILLING_FIREHOSE_NAME}-role"
FIREHOSE_POLICY="${BILLING_FIREHOSE_NAME}-policy"
LOGS_TO_FH_ROLE="${BILLING_FIREHOSE_NAME}-logs-to-fh-role"
LOGS_TO_FH_POLICY="${BILLING_FIREHOSE_NAME}-logs-to-fh-policy"

echo "[D1] Disable API Gateway access logging"
if [[ -n "${API_ID}" && "${API_ID}" != "None" ]]; then
  aws apigatewayv2 delete-access-log-settings \
    --api-id "${API_ID}" \
    --stage-name '$default' >/dev/null 2>&1 || true
fi

echo "[D2] Remove CloudWatch Logs subscription filters"
# 로그 그룹 존재 시 구독 전량 삭제
if aws logs describe-log-groups --log-group-name-prefix "${BILLING_LOG_GROUP}" \
  --query 'logGroups[0].logGroupName' --output text | grep -q "${BILLING_LOG_GROUP}"; then
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
fi
aws logs delete-resource-policy --policy-name "FirehoseSubscriptionPolicy" >/dev/null 2>&1 || true

echo "[D3] Delete Firehose stream"
aws firehose delete-delivery-stream \
  --delivery-stream-name "${BILLING_FIREHOSE_NAME}" \
  --allow-force-delete true >/dev/null 2>&1 || true

echo "[D4] Delete IAM roles and policies"
# Firehose S3 전송 역할/정책
aws iam detach-role-policy \
  --role-name "${FIREHOSE_ROLE}" \
  --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${FIREHOSE_POLICY}" >/dev/null 2>&1 || true
aws iam delete-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${FIREHOSE_POLICY}" >/dev/null 2>&1 || true
aws iam delete-role --role-name "${FIREHOSE_ROLE}" >/dev/null 2>&1 || true

# CloudWatch Logs → Firehose 구독 역할/정책
aws iam detach-role-policy \
  --role-name "${LOGS_TO_FH_ROLE}" \
  --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${LOGS_TO_FH_POLICY}" >/dev/null 2>&1 || true
aws iam delete-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${LOGS_TO_FH_POLICY}" >/dev/null 2>&1 || true
aws iam delete-role --role-name "${LOGS_TO_FH_ROLE}" >/dev/null 2>&1 || true

echo "[D5] Drop Athena view/tables and workgroup"
aws athena start-query-execution --work-group "${BILLING_ATHENA_WORKGROUP}" \
  --query-string "DROP VIEW IF EXISTS ${BILLING_GLUE_DB}.${BILLING_TABLE_JSON};" >/dev/null 2>&1 || true
aws athena start-query-execution --work-group "${BILLING_ATHENA_WORKGROUP}" \
  --query-string "DROP TABLE IF EXISTS ${BILLING_GLUE_DB}.${BILLING_TABLE_JSON}_raw;" >/dev/null 2>&1 || true
aws athena start-query-execution --work-group "${BILLING_ATHENA_WORKGROUP}" \
  --query-string "DROP TABLE IF EXISTS ${BILLING_GLUE_DB}.${BILLING_TABLE_PARQUET};" >/dev/null 2>&1 || true
aws glue delete-database --name "${BILLING_GLUE_DB}" >/dev/null 2>&1 || true
aws athena delete-work-group --work-group "${BILLING_ATHENA_WORKGROUP}" --recursive-delete-option >/dev/null 2>&1 || true

echo "[D6] Empty and delete S3 bucket for logs"
aws s3 rb "s3://${BILLING_S3_BUCKET}" --force >/dev/null 2>&1 || true

echo "[D7] Delete log groups"
aws logs delete-log-group --log-group-name "${BILLING_LOG_GROUP}" >/dev/null 2>&1 || true
aws logs delete-log-group --log-group-name "/aws/kinesisfirehose/${BILLING_FIREHOSE_NAME}" >/dev/null 2>&1 || true

echo "[DONE] Billing pipeline destroyed."
