#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# Athena - Glue - Tables setup for API GW Billing
# This version hardens RAW table parsing and the view logic
# ------------------------------------------------------------------------------

# 0. env
source .env
aws configure set region "${AWS_REGION}"

# 1. helper
wait_for_query() {
  local qid="$1"
  local desc="${2:-Query}"
  echo "  → Waiting for ${desc} to complete (query_id: ${qid})..."
  for i in {1..120}; do
    local status
    status=$(aws athena get-query-execution --query-execution-id "${qid}" --query 'QueryExecution.Status.State' --output text)
    case "${status}" in
      SUCCEEDED)
        echo "  ✓ ${desc} SUCCEEDED"
        return 0
        ;;
      FAILED|CANCELLED)
        echo "  ✗ ${desc} ${status}"
        aws athena get-query-execution --query-execution-id "${qid}" --output json | jq -r '.QueryExecution.Status.StateChangeReason'
        return 1
        ;;
      RUNNING|QUEUED|SUBMITTED|"")
        sleep 1
        ;;
    esac
  done
  echo "  ✗ ${desc} timed out after 120s"
  return 1
}

start_query() {
  local sql="$1"
  local desc="$2"
  local qid
  qid=$(aws athena start-query-execution \
      --work-group "${BILLING_ATHENA_WORKGROUP}" \
      --query-string "${sql}" \
      --query 'QueryExecutionId' --output text)
  wait_for_query "${qid}" "${desc}"
}

# 2. ensure WorkGroup
echo "[1] Ensure Athena WorkGroup: ${BILLING_ATHENA_WORKGROUP}"
if ! aws athena get-work-group --work-group "${BILLING_ATHENA_WORKGROUP}" >/dev/null 2>&1; then
  aws athena create-work-group \
    --name "${BILLING_ATHENA_WORKGROUP}" \
    --configuration "ResultConfiguration={OutputLocation=s3://${BILLING_S3_BUCKET}/athena-results/}" >/dev/null
  echo "  ✓ WorkGroup created"
else
  # ensure output location is set
  aws athena update-work-group \
    --work-group "${BILLING_ATHENA_WORKGROUP}" \
    --state ENABLED \
    --configuration-updates "ResultConfigurationUpdates={OutputLocation=s3://${BILLING_S3_BUCKET}/athena-results/}" >/dev/null || true
  echo "  ✓ WorkGroup exists"
fi

# 3. ensure Glue Database
echo "[2] Ensure Glue Database: ${BILLING_GLUE_DB}"
if ! aws glue get-database --name "${BILLING_GLUE_DB}" >/dev/null 2>&1; then
  aws glue create-database --database-input "Name=${BILLING_GLUE_DB}" >/dev/null
  echo "  ✓ Database created"
else
  echo "  ✓ Database exists"
fi

# 4. DDL - RAW table drop and create (hardened)
RAW_TABLE="${BILLING_GLUE_DB}.${BILLING_TABLE_JSON}_raw"
VIEW_NAME="${BILLING_GLUE_DB}.${BILLING_TABLE_JSON}"
PARQUET_TABLE="${BILLING_GLUE_DB}.${BILLING_TABLE_PARQUET}"

echo "[3] Create or replace RAW table: ${RAW_TABLE}"

SQL_DROP_RAW="DROP TABLE IF EXISTS ${RAW_TABLE};"
SQL_CREATE_RAW=$(cat <<'SQL'
CREATE EXTERNAL TABLE %RAW_TABLE%(
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
WITH SERDEPROPERTIES (
  'ignore.malformed.json'='true'        -- tolerate empty or slightly malformed lines
)
STORED AS INPUTFORMAT 'org.apache.hadoop.mapred.TextInputFormat'
OUTPUTFORMAT 'org.apache.hadoop.hive.ql.io.IgnoreKeyTextOutputFormat'
LOCATION 's3://%BUCKET%/json-data';
SQL
)
SQL_CREATE_RAW="${SQL_CREATE_RAW//'%'RAW_TABLE'%'/${RAW_TABLE}}"
SQL_CREATE_RAW="${SQL_CREATE_RAW//'%'BUCKET'%'/${BILLING_S3_BUCKET}}"

start_query "${SQL_DROP_RAW}" "Drop RAW table"
start_query "${SQL_CREATE_RAW}" "Create RAW table"

# 5. Repair partitions
echo "[4] MSCK REPAIR on RAW table"
SQL_REPAIR="MSCK REPAIR TABLE ${RAW_TABLE};"
start_query "${SQL_REPAIR}" "MSCK REPAIR"

# 6. View - parse JSON and auto-correct requestTime unit, filter DATA_MESSAGE
echo "[5] Create or replace VIEW: ${VIEW_NAME}"
SQL_CREATE_VIEW=$(cat <<'SQL'
CREATE OR REPLACE VIEW %VIEW_NAME% AS
WITH base AS (
  SELECT
    json_extract_scalar(log.message, '$.requestId') AS requestId,
    json_extract_scalar(log.message, '$.ip') AS ip,
    json_extract_scalar(log.message, '$.user') AS user,
    json_extract_scalar(log.message, '$.sub') AS sub,
    CAST(json_extract_scalar(log.message, '$.requestTime') AS bigint) AS requestTime_raw,
    json_extract_scalar(log.message, '$.httpMethod') AS httpMethod,
    json_extract_scalar(log.message, '$.path') AS path,
    json_extract_scalar(log.message, '$.routeKey') AS routeKey,
    json_extract_scalar(log.message, '$.status') AS status,
    json_extract_scalar(log.message, '$.protocol') AS protocol,
    CAST(json_extract_scalar(log.message, '$.responseLength') AS bigint) AS responseLength,
    raw.year, raw.month, raw.day, raw.hour
  FROM %RAW_TABLE% raw
  CROSS JOIN UNNEST(raw.logEvents) AS t(log)
  WHERE raw.messageType = 'DATA_MESSAGE'
)
SELECT
  requestId, ip, user, sub, httpMethod, path, routeKey, status, protocol, responseLength,
  CASE
    WHEN requestTime_raw >= 1000000000000 THEN requestTime_raw
    ELSE requestTime_raw * 1000
  END AS requestTime,
  year, month, day, hour
FROM base;
SQL
)
SQL_CREATE_VIEW="${SQL_CREATE_VIEW//'%'VIEW_NAME'%'/${VIEW_NAME}}"
SQL_CREATE_VIEW="${SQL_CREATE_VIEW//'%'RAW_TABLE'%'/${RAW_TABLE}}"
start_query "${SQL_CREATE_VIEW}" "Create VIEW"

# 7. Optional - Parquet aggregated table (CTAS). It is okay if it fails when no data yet.
echo "[6] Create Parquet aggregated table (optional): ${PARQUET_TABLE}"
SQL_DROP_PARQUET="DROP TABLE IF EXISTS ${PARQUET_TABLE};"
# Note: Uses view columns. req_date derived in UTC. You can change to Asia/Seoul if needed.
SQL_CREATE_PARQUET=$(cat <<'SQL'
CREATE TABLE %PARQUET_TABLE%
WITH (
  format = 'PARQUET',
  parquet_compression = 'SNAPPY',
  external_location = 's3://%BUCKET%/%PARQUET_PREFIX%',
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
  year(from_unixtime(requestTime/1000))  AS year,
  month(from_unixtime(requestTime/1000)) AS month,
  day(from_unixtime(requestTime/1000))   AS day,
  COUNT(*) AS calls,
  SUM(responseLength) AS total_bytes
FROM %VIEW_NAME%
GROUP BY
  user, sub, httpMethod, path, routeKey, status,
  date_format(from_unixtime(requestTime/1000), '%Y-%m-%d'),
  year(from_unixtime(requestTime/1000)),
  month(from_unixtime(requestTime/1000)),
  day(from_unixtime(requestTime/1000));
SQL
)
SQL_CREATE_PARQUET="${SQL_CREATE_PARQUET//'%'VIEW_NAME'%'/${VIEW_NAME}}"
SQL_CREATE_PARQUET="${SQL_CREATE_PARQUET//'%'PARQUET_TABLE'%'/${PARQUET_TABLE}}"
SQL_CREATE_PARQUET="${SQL_CREATE_PARQUET//'%'BUCKET'%'/${BILLING_S3_BUCKET}}"
SQL_CREATE_PARQUET="${SQL_CREATE_PARQUET//'%'PARQUET_PREFIX'%'/${BILLING_PARQUET_PREFIX}}"

start_query "${SQL_DROP_PARQUET}" "Drop Parquet table" || true
start_query "${SQL_CREATE_PARQUET}" "Create Parquet table" || echo "  [WARN] Parquet CTAS skipped or failed - likely no data yet"

# 8. Print handy sanity queries
cat <<'EOT'

[OK] Athena setup complete!
  → Raw table: ${BILLING_GLUE_DB}.${BILLING_TABLE_JSON}_raw
  → View:      ${BILLING_GLUE_DB}.${BILLING_TABLE_JSON}
  → Parquet:   ${BILLING_GLUE_DB}.${BILLING_TABLE_PARQUET}

===== Quick sanity queries =====
-- 파티션 목록
SHOW PARTITIONS ${BILLING_GLUE_DB}.${BILLING_TABLE_JSON}_raw;

-- 시간대별 행수
SELECT year,month,day,hour,COUNT(*) AS rows
FROM ${BILLING_GLUE_DB}.${BILLING_TABLE_JSON}_raw
GROUP BY 1,2,3,4
ORDER BY 1 DESC,2 DESC,3 DESC,4 DESC;

-- 특정 파티션에서 RAW 한 줄 확인 - YYYY/MM/DD/HH 값 채워 사용
SELECT messageType,
       element_at(TRANSFORM(logEvents, x -> x.message), 1) AS sample_message
FROM ${BILLING_GLUE_DB}.${BILLING_TABLE_JSON}_raw
WHERE year=YYYY AND month=MM AND day=DD AND hour=HH
LIMIT 5;

-- 뷰에서 최근 10건
SELECT requestId, ip, httpMethod, routeKey, status, from_unixtime(requestTime/1000) AS ts
FROM ${BILLING_GLUE_DB}.${BILLING_TABLE_JSON}
ORDER BY requestTime DESC
LIMIT 10;
================================
EOT

echo "[DONE]"

