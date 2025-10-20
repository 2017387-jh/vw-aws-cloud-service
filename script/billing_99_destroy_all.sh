#!/usr/bin/env bash
set -euo pipefail

# .env 사용
source .env
aws configure set region "${AWS_REGION}"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
API_ID=$(aws apigatewayv2 get-apis --query "Items[?Name=='${DDN_APIGW_NAME}'].ApiId" --output text || true)
STAGE_NAME="${DDN_APIGW_STAGE_NAME:-\$default}"

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

echo "[D2] Remove all subscription filters on ${BILLING_LOG_GROUP}"
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

echo "[D4] Delete IAM roles/policies"
aws iam detach-role-policy --role-name "${FIREHOSE_ROLE}" \
  --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${FIREHOSE_POLICY}" >/dev/null 2>&1 || true
aws iam delete-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${FIREHOSE_POLICY}" >/dev/null 2>&1 || true
aws iam delete-role --role-name "${FIREHOSE_ROLE}" >/dev/null 2>&1 || true

aws iam detach-role-policy --role-name "${LOGS_TO_FH_ROLE}" \
  --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${LOGS_TO_FH_POLICY}" >/dev/null 2>&1 || true
aws iam delete-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${LOGS_TO_FH_POLICY}" >/dev/null 2>&1 || true
aws iam delete-role --role-name "${LOGS_TO_FH_ROLE}" >/dev/null 2>&1 || true

echo "[D5] Drop Athena table(s) & workgroup"
# 지금 버전만 유지: 단일 JSON 테이블/Parquet 집계 테이블만 드롭
aws athena start-query-execution --work-group "${BILLING_ATHENA_WORKGROUP}" \
  --query-string "DROP TABLE IF EXISTS ${BILLING_GLUE_DB}.${BILLING_TABLE_PARQUET};" >/dev/null 2>&1 || true
aws athena start-query-execution --work-group "${BILLING_ATHENA_WORKGROUP}" \
  --query-string "DROP TABLE IF EXISTS ${BILLING_GLUE_DB}.${BILLING_TABLE_JSON};" >/dev/null 2>&1 || true

# Glue DB 삭제(남은 테이블 없으면 성공)
aws glue delete-database --name "${BILLING_GLUE_DB}" >/dev/null 2>&1 || true

# 워크그룹 삭제
aws athena delete-work-group --work-group "${BILLING_ATHENA_WORKGROUP}" --recursive-delete-option >/dev/null 2>&1 || true

echo "[D6] Empty & delete S3 bucket (logs + athena results)"
aws s3 rb "s3://${BILLING_S3_BUCKET}" --force >/dev/null 2>&1 || true

echo "[D7] Delete log groups"
aws logs delete-log-group --log-group-name "${BILLING_LOG_GROUP}" >/dev/null 2>&1 || true
aws logs delete-log-group --log-group-name "/aws/kinesisfirehose/${BILLING_FIREHOSE_NAME}" >/dev/null 2>&1 || true

echo "[DONE] Billing pipeline destroyed."
