#!/usr/bin/env bash
set -euo pipefail
source .env
aws configure set region "${AWS_REGION}"

echo "[1] Create/ensure Athena workgroup"
aws athena get-work-group --work-group "${BILLING_ATHENA_WORKGROUP}" >/dev/null 2>&1 || \
aws athena create-work-group --name "${BILLING_ATHENA_WORKGROUP}" \
  --configuration ResultConfiguration={OutputLocation=s3://${BILLING_S3_BUCKET}/athena-results/} >/dev/null

echo "[2] Create Glue database if not exists"
aws glue get-database --name "${BILLING_GLUE_DB}" >/dev/null 2>&1 || \
aws glue create-database --database-input "Name=${BILLING_GLUE_DB}" >/dev/null

echo "[3] Create EXTERNAL JSON table for CloudWatch Logs format"
# First, create a raw table for CloudWatch Logs subscription filter format
SQL_CREATE_RAW_TABLE=$(cat <<EOF
CREATE EXTERNAL TABLE IF NOT EXISTS ${BILLING_GLUE_DB}.${BILLING_TABLE_JSON}_raw(
  messageType string,
  owner string,
  logGroup string,
  logStream string,
  subscriptionFilters array<string>,
  logEvents array<struct<
    id:string,
    timestamp:bigint,
    message:string
  >>
)
PARTITIONED BY (year int, month int, day int, hour int)
ROW FORMAT SERDE 'org.openx.data.jsonserde.JsonSerDe'
WITH SERDEPROPERTIES ('ignore.malformed.json'='true')
STORED AS INPUTFORMAT 'org.apache.hadoop.mapred.TextInputFormat'
OUTPUTFORMAT 'org.apache.hadoop.hive.ql.io.IgnoreKeyTextOutputFormat'
LOCATION 's3://${BILLING_S3_BUCKET}/json-data';
EOF
)

# Create a view that extracts the actual log data from the message field
SQL_CREATE_JSON_VIEW=$(cat <<EOF
CREATE OR REPLACE VIEW ${BILLING_GLUE_DB}.${BILLING_TABLE_JSON} AS
SELECT
  json_extract_scalar(log.message, '\$.requestId') AS requestId,
  json_extract_scalar(log.message, '\$.ip') AS ip,
  json_extract_scalar(log.message, '\$.user') AS user,
  json_extract_scalar(log.message, '\$.sub') AS sub,
  CAST(json_extract_scalar(log.message, '\$.requestTime') AS bigint) AS requestTime,
  json_extract_scalar(log.message, '\$.httpMethod') AS httpMethod,
  json_extract_scalar(log.message, '\$.path') AS path,
  json_extract_scalar(log.message, '\$.routeKey') AS routeKey,
  json_extract_scalar(log.message, '\$.status') AS status,
  json_extract_scalar(log.message, '\$.protocol') AS protocol,
  CAST(json_extract_scalar(log.message, '\$.responseLength') AS bigint) AS responseLength,
  raw.year,
  raw.month,
  raw.day,
  raw.hour
FROM ${BILLING_GLUE_DB}.${BILLING_TABLE_JSON}_raw raw
CROSS JOIN UNNEST(raw.logEvents) AS t(log);
EOF
)

aws athena start-query-execution \
  --query-string "CREATE DATABASE IF NOT EXISTS ${BILLING_GLUE_DB};" \
  --work-group "${BILLING_ATHENA_WORKGROUP}" >/dev/null

echo "[3.1] Create raw table"
aws athena start-query-execution \
  --query-string "${SQL_CREATE_RAW_TABLE}" \
  --work-group "${BILLING_ATHENA_WORKGROUP}" >/dev/null

echo "[3.2] Create view for parsed logs"
aws athena start-query-execution \
  --query-string "${SQL_CREATE_JSON_VIEW}" \
  --work-group "${BILLING_ATHENA_WORKGROUP}" >/dev/null

echo "[4] MSCK REPAIR to load partitions"
aws athena start-query-execution \
  --query-string "MSCK REPAIR TABLE ${BILLING_GLUE_DB}.${BILLING_TABLE_JSON}_raw;" \
  --work-group "${BILLING_ATHENA_WORKGROUP}" >/dev/null

echo "[5] (Optional) Parquet daily aggregation CTAS (includes routeKey)"
PARQUET_LOC="s3://${BILLING_S3_BUCKET}/${BILLING_PARQUET_PREFIX}"
SQL_CREATE_PARQUET_TEMPLATE=$(cat <<'EOF'
CREATE TABLE IF NOT EXISTS ${DB}.${TBL}
WITH (
  format = 'PARQUET',
  parquet_compression = 'SNAPPY',
  partitioned_by = ARRAY['year','month','day']
) AS
SELECT user, sub, httpMethod, path, routeKey, status,
       date_format(from_unixtime(requestTime/1000), '%Y-%m-%d') AS req_date,
       year(from_unixtime(requestTime/1000))  AS year,
       month(from_unixtime(requestTime/1000)) AS month,
       day(from_unixtime(requestTime/1000))   AS day,
       count(*) AS calls, sum(responseLength) AS total_bytes
FROM ${SRC_DB}.${SRC_TBL}
GROUP BY user, sub, httpMethod, path, routeKey, status,
         date_format(from_unixtime(requestTime/1000), '%Y-%m-%d'),
         year(from_unixtime(requestTime/1000)),
         month(from_unixtime(requestTime/1000)),
         day(from_unixtime(requestTime/1000));
EOF
)
SQL_CREATE_PARQUET="${SQL_CREATE_PARQUET_TEMPLATE}"
SQL_CREATE_PARQUET="${SQL_CREATE_PARQUET//\$\{DB\}/${BILLING_GLUE_DB}}"
SQL_CREATE_PARQUET="${SQL_CREATE_PARQUET//\$\{TBL\}/${BILLING_TABLE_PARQUET}}"
SQL_CREATE_PARQUET="${SQL_CREATE_PARQUET//\$\{SRC_DB\}/${BILLING_GLUE_DB}}"
SQL_CREATE_PARQUET="${SQL_CREATE_PARQUET//\$\{SRC_TBL\}/${BILLING_TABLE_JSON}}"

aws athena start-query-execution \
  --query-string "${SQL_CREATE_PARQUET}" \
  --work-group "${BILLING_ATHENA_WORKGROUP}" >/dev/null

echo "[OK] Athena ready → ${BILLING_TABLE_JSON}, ${BILLING_TABLE_PARQUET}"
