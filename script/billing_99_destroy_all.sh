#!/usr/bin/env bash
set -euo pipefail
source .env
aws configure set region "${AWS_REGION}"

echo "[D1] Disable API GW access logging"
API_ID=$(aws apigatewayv2 get-apis --query "Items[?Name=='${DDN_APIGW_NAME}'].ApiId" --output text)
if [[ -n "${API_ID}" && "${API_ID}" != "None" ]]; then
  aws apigatewayv2 update-stage --api-id "${API_ID}" --stage-name "${DDN_APIGW_STAGE_NAME:-$default}" \
    --access-log-settings "DestinationArn=,Format=" >/dev/null || true
fi

echo "[D2] Remove log subscription filter"
aws logs delete-subscription-filter --log-group-name "${BILLING_LOG_GROUP}" --filter-name "ToFirehose" >/dev/null 2>&1 || true

echo "[D3] Delete Firehose stream"
aws firehose delete-delivery-stream --delivery-stream-name "${BILLING_FIREHOSE_NAME}" --allow-force-delete true >/dev/null 2>&1 || true

echo "[D4] Delete IAM policy/role"
aws iam detach-role-policy --role-name "${BILLING_FIREHOSE_NAME}-role" --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${BILLING_FIREHOSE_NAME}-policy" >/dev/null 2>&1 || true
aws iam delete-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${BILLING_FIREHOSE_NAME}-policy" >/dev/null 2>&1 || true
aws iam delete-role --role-name "${BILLING_FIREHOSE_NAME}-role" >/dev/null 2>&1 || true

echo "[D5] Delete Athena tables/workgroup (data in S3 remains)"
aws athena start-query-execution --work-group "${BILLING_ATHENA_WORKGROUP}" --query-string "DROP TABLE IF EXISTS ${BILLING_GLUE_DB}.${BILLING_TABLE_PARQUET};" >/dev/null 2>&1 || true
aws athena start-query-execution --work-group "${BILLING_ATHENA_WORKGROUP}" --query-string "DROP TABLE IF EXISTS ${BILLING_GLUE_DB}.${BILLING_TABLE_JSON};" >/dev/null 2>&1 || true
aws glue delete-database --name "${BILLING_GLUE_DB}" >/dev/null 2>&1 || true
aws athena delete-work-group --work-group "${BILLING_ATHENA_WORKGROUP}" --recursive-delete-option >/dev/null 2>&1 || true

echo "[D6] Empty & delete S3 bucket"
aws s3 rb "s3://${BILLING_S3_BUCKET}" --force >/dev/null 2>&1 || true

echo "[D7] Delete log group"
aws logs delete-log-group --log-group-name "${BILLING_LOG_GROUP}" >/dev/null 2>&1 || true

echo "[DONE] Billing pipeline destroyed."
