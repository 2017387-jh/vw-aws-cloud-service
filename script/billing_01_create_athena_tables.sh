#!/usr/bin/env bash
set -euo pipefail
source .env
aws configure set region "${AWS_REGION}"

echo "[A] Create/ensure Athena workgroup"
aws athena get-work-group --work-group "${BILLING_ATHENA_WORKGROUP}" >/dev/null 2>&1 || \
aws athena create-work-group --name "${BILLING_ATHENA_WORKGROUP}" \
    --configuration ResultConfiguration={OutputLocation=s3://${BILLING_S3_BUCKET}/athena-results/} >/dev/null

echo "[B] Create Glue database if not exists"
aws glue get-database --name "${BILLING_GLUE_DB}" >/dev/null 2>&1 || \
aws glue create-database --database-input "Name=${BILLING_GLUE_DB}" >/dev/null

S3_JSON_PREFIX="s3://${BILLING_S3_BUCKET}/json-data"

SQL_CREATE_DB="CREATE DATABASE IF NOT EXISTS ${BILLING_GLUE_DB};"
SQL_CREATE_JSON_TABLE=$(cat <<EOF
CREATE EXTERNAL TABLE IF NOT EXISTS ${BILLING_GLUE_DB}.${BILLING_TABLE_JSON}(
  requestId string,
  ip string,
  user string,
  sub string,
  requestTime timestamp,
  httpMethod string,
  resourcePath string,
  status string,
  protocol string,
  responseLength bigint
)
PARTITIONED BY (year int, month int, day int, hour int)
ROW FORMAT SERDE 'org.openx.data.jsonserde.JsonSerDe'
STORED AS INPUTFORMAT 'org.apache.hadoop.mapred.TextInputFormat'
OUTPUTFORMAT 'org.apache.hadoop.hive.ql.io.IgnoreKeyTextOutputFormat'
LOCATION '${S3_JSON_PREFIX}';
EOF
)

echo "[C] Create DB & JSON table"
aws athena start-query-execution \
  --query-string "${SQL_CREATE_DB}" \
  --work-group "${BILLING_ATHENA_WORKGROUP}" >/dev/null
aws athena start-query-execution \
  --query-string "${SQL_CREATE_JSON_TABLE}" \
  --work-group "${BILLING_ATHENA_WORKGROUP}" >/dev/null

echo "[D] MSCK REPAIR to load partitions"
aws athena start-query-execution \
  --query-string "MSCK REPAIR TABLE ${BILLING_GLUE_DB}.${BILLING_TABLE_JSON};" \
  --work-group "${BILLING_ATHENA_WORKGROUP}" >/dev/null

echo "[E] (Optional) Parquet CTAS daily aggregation table"
PARQUET_LOC="s3://${BILLING_S3_BUCKET}/${BILLING_PARQUET_PREFIX}"
SQL_CREATE_PARQUET=$(cat <<'EOF'
CREATE TABLE IF NOT EXISTS ${DB}.${TBL}
WITH (
  format = 'PARQUET',
  parquet_compression = 'SNAPPY',
  external_location = '${LOC}',
  partitioned_by = ARRAY['year','month','day']
) AS
SELECT user, sub, httpMethod, resourcePath, status,
       date_format(from_unixtime(requestTime/1000), '%Y-%m-%d') AS req_date,
       year(from_unixtime(requestTime/1000))  AS year,
       month(from_unixtime(requestTime/1000)) AS month,
       day(from_unixtime(requestTime/1000))   AS day,
       count(*) AS calls, sum(responseLength) AS total_bytes
FROM ${SRC_DB}.${SRC_TBL}
GROUP BY user, sub, httpMethod, resourcePath, status,
         date_format(from_unixtime(requestTime/1000), '%Y-%m-%d'),
         year(from_unixtime(requestTime/1000)),
         month(from_unixtime(requestTime/1000)),
         day(from_unixtime(requestTime/1000));
EOF
)
SQL_CREATE_PARQUET="${SQL_CREATE_PARQUET//\$\{DB\}/${BILLING_GLUE_DB}}"
SQL_CREATE_PARQUET="${SQL_CREATE_PARQUET//\$\{TBL\}/${BILLING_TABLE_PARQUET}}"
SQL_CREATE_PARQUET="${SQL_CREATE_PARQUET//\$\{LOC\}/${PARQUET_LOC}}"
SQL_CREATE_PARQUET="${SQL_CREATE_PARQUET//\$\{SRC_DB\}/${BILLING_GLUE_DB}}"
SQL_CREATE_PARQUET="${SQL_CREATE_PARQUET//\$\{SRC_TBL\}/${BILLING_TABLE_JSON}}"

aws athena start-query-execution \
  --query-string "${SQL_CREATE_PARQUET}" \
  --work-group "${BILLING_ATHENA_WORKGROUP}" >/dev/null

echo "[OK] Athena tables ready: ${BILLING_TABLE_JSON}, ${BILLING_TABLE_PARQUET}"
