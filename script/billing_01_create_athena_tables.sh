#!/usr/bin/env bash
set -euo pipefail
source .env
aws configure set region "${AWS_REGION}"

# Helper function to wait for Athena query completion
wait_for_query() {
  local qid="$1"
  local desc="${2:-Query}"
  echo "  → Waiting for ${desc} to complete (query_id: ${qid})..."

  for i in {1..60}; do
    STATUS=$(aws athena get-query-execution --query-execution-id "${qid}" \
      --query 'QueryExecution.Status.State' --output text 2>/dev/null || echo "UNKNOWN")

    case "${STATUS}" in
      SUCCEEDED)
        echo "  ✓ ${desc} completed successfully"
        return 0
        ;;
      FAILED|CANCELLED)
        echo "  ✗ ${desc} failed with status: ${STATUS}"
        aws athena get-query-execution --query-execution-id "${qid}" \
          --query 'QueryExecution.Status.StateChangeReason' --output text 2>/dev/null || true
        return 1
        ;;
      QUEUED|RUNNING)
        sleep 2
        ;;
      *)
        echo "  ? Unknown status: ${STATUS}"
        sleep 2
        ;;
    esac
  done

  echo "  ✗ ${desc} timed out after 120 seconds"
  return 1
}

echo "[1] Create/ensure Athena workgroup"
aws athena get-work-group --work-group "${BILLING_ATHENA_WORKGROUP}" >/dev/null 2>&1 || \
aws athena create-work-group --name "${BILLING_ATHENA_WORKGROUP}" \
  --configuration ResultConfiguration={OutputLocation=s3://${BILLING_S3_BUCKET}/athena-results/} >/dev/null

echo "[2] Create Glue database if not exists"
aws glue get-database --name "${BILLING_GLUE_DB}" >/dev/null 2>&1 || \
aws glue create-database --database-input "Name=${BILLING_GLUE_DB}" >/dev/null

echo "[3] Create EXTERNAL JSON table for CloudWatch Logs format"
# Firehose now adds newline delimiter between records
# Each line is a separate JSON object from CloudWatch Logs subscription filter
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

echo "[3.0] Create database"
QID=$(aws athena start-query-execution \
  --query-string "CREATE DATABASE IF NOT EXISTS ${BILLING_GLUE_DB};" \
  --work-group "${BILLING_ATHENA_WORKGROUP}" \
  --query 'QueryExecutionId' --output text)
wait_for_query "${QID}" "Create database"

echo "[3.1] Create raw table"
QID=$(aws athena start-query-execution \
  --query-string "${SQL_CREATE_RAW_TABLE}" \
  --work-group "${BILLING_ATHENA_WORKGROUP}" \
  --query 'QueryExecutionId' --output text)
wait_for_query "${QID}" "Create raw table"

echo "[3.2] Create view for parsed logs"
QID=$(aws athena start-query-execution \
  --query-string "${SQL_CREATE_JSON_VIEW}" \
  --work-group "${BILLING_ATHENA_WORKGROUP}" \
  --query 'QueryExecutionId' --output text)
wait_for_query "${QID}" "Create view"

echo "[4] MSCK REPAIR to load partitions"
QID=$(aws athena start-query-execution \
  --query-string "MSCK REPAIR TABLE ${BILLING_GLUE_DB}.${BILLING_TABLE_JSON}_raw;" \
  --work-group "${BILLING_ATHENA_WORKGROUP}" \
  --query 'QueryExecutionId' --output text)
wait_for_query "${QID}" "MSCK REPAIR"

echo "[5] (Optional) Parquet daily aggregation CTAS (includes routeKey)"
PARQUET_LOC="s3://${BILLING_S3_BUCKET}/${BILLING_PARQUET_PREFIX}"
SQL_CREATE_PARQUET_TEMPLATE=$(cat <<'EOF'
CREATE TABLE IF NOT EXISTS ${DB}.${TBL}
WITH (
  format = 'PARQUET',
  parquet_compression = 'SNAPPY',
  partitioned_by = ARRAY['year','month','day']
) AS
SELECT
       user,
       sub,
       httpMethod,
       path,
       routeKey,
       status,
       date_format(from_unixtime(requestTime/1000), '%Y-%m-%d') AS req_date,
       count(*) AS calls,
       sum(responseLength) AS total_bytes,
       year(from_unixtime(requestTime/1000))  AS year,
       month(from_unixtime(requestTime/1000)) AS month,
       day(from_unixtime(requestTime/1000))   AS day
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

echo "[5.1] Drop existing Parquet table if exists"
QID=$(aws athena start-query-execution \
  --query-string "DROP TABLE IF EXISTS ${BILLING_GLUE_DB}.${BILLING_TABLE_PARQUET};" \
  --work-group "${BILLING_ATHENA_WORKGROUP}" \
  --query 'QueryExecutionId' --output text 2>/dev/null || echo "")
if [ -n "$QID" ]; then
  wait_for_query "${QID}" "Drop Parquet table" || true
fi

echo "[5.2] Clean up failed Parquet data location"
aws s3 rm "s3://${BILLING_S3_BUCKET}/athena-results/tables/" --recursive >/dev/null 2>&1 || true

echo "[5.3] Create Parquet aggregation table (CTAS)"
QID=$(aws athena start-query-execution \
  --query-string "${SQL_CREATE_PARQUET}" \
  --work-group "${BILLING_ATHENA_WORKGROUP}" \
  --query 'QueryExecutionId' --output text)
wait_for_query "${QID}" "Create Parquet table" || echo "  [WARN] Parquet table creation failed (may need data first)"

echo ""
echo "[OK] Athena setup complete!"
echo "  → Raw table: ${BILLING_GLUE_DB}.${BILLING_TABLE_JSON}_raw"
echo "  → View: ${BILLING_GLUE_DB}.${BILLING_TABLE_JSON}"
echo "  → Parquet table: ${BILLING_GLUE_DB}.${BILLING_TABLE_PARQUET}"
echo ""
echo "Test queries:"
echo "  SELECT * FROM ${BILLING_GLUE_DB}.${BILLING_TABLE_JSON}_raw LIMIT 5;"
echo "  SELECT * FROM ${BILLING_GLUE_DB}.${BILLING_TABLE_JSON} LIMIT 5;"
