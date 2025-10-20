#!/usr/bin/env bash
set -euo pipefail
source .env
aws configure set region "${AWS_REGION}"

echo "[1] Ensure Athena workgroup"
aws athena get-work-group --work-group "${BILLING_ATHENA_WORKGROUP}" >/dev/null 2>&1 || \
aws athena create-work-group --name "${BILLING_ATHENA_WORKGROUP}" \
  --configuration ResultConfiguration={OutputLocation=s3://${BILLING_S3_BUCKET}/athena-results/} >/dev/null

echo "[2] Ensure Glue database"
aws glue get-database --name "${BILLING_GLUE_DB}" >/dev/null 2>&1 || \
aws glue create-database --database-input "Name=${BILLING_GLUE_DB}" >/dev/null

S3_JSON_PREFIX="s3://${BILLING_S3_BUCKET}/json-data"

# RAW 텍스트 테이블 (한 줄=한 레코드 문자열)
SQL_CREATE_JSON_RAW=$(cat <<EOF
CREATE EXTERNAL TABLE IF NOT EXISTS ${BILLING_GLUE_DB}.${BILLING_TABLE_JSON}_raw(
  line string
)
PARTITIONED BY (year int, month int, day int, hour int)
ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'
STORED AS INPUTFORMAT 'org.apache.hadoop.mapred.TextInputFormat'
OUTPUTFORMAT 'org.apache.hadoop.hive.ql.io.IgnoreKeyTextOutputFormat'
LOCATION '${S3_JSON_PREFIX}';
EOF
)

# 파싱 뷰 (CloudWatch Logs 데이터 메시지 래퍼 → logEvents[].message JSON 파싱)
SQL_CREATE_VIEW=$(cat <<'EOF'
CREATE OR REPLACE VIEW ${DB}.${VIEW} AS
WITH src AS (
  SELECT json_parse(line) AS j
  FROM ${DB}.${RAW}
  WHERE json_extract_scalar(line, '$.messageType') = 'DATA_MESSAGE'
),
ev AS (
  SELECT ev_json
  FROM src
  CROSS JOIN UNNEST(CAST(json_extract(j, '$.logEvents') AS array(json))) AS t(ev_json)
),
msg AS (
  -- message 필드는 이스케이프된 JSON 문자열 → 다시 파싱
  SELECT json_parse(json_extract_scalar(ev_json, '$.message')) AS m
  FROM ev
)
SELECT
  json_extract_scalar(m, '$.requestId')                              AS requestId,
  json_extract_scalar(m, '$.ip')                                     AS ip,
  json_extract_scalar(m, '$.user')                                   AS user,
  json_extract_scalar(m, '$.sub')                                    AS sub,
  CAST(json_extract_scalar(m, '$.requestTime') AS BIGINT)            AS requestTime,
  json_extract_scalar(m, '$.httpMethod')                              AS httpMethod,
  json_extract_scalar(m, '$.path')                                    AS path,
  json_extract_scalar(m, '$.routeKey')                                AS routeKey,
  json_extract_scalar(m, '$.status')                                  AS status,
  json_extract_scalar(m, '$.protocol')                                AS protocol,
  CAST(json_extract_scalar(m, '$.responseLength') AS BIGINT)          AS responseLength,
  -- 날짜 파생 컬럼(파티션용)
  CAST(date_format(from_unixtime(CAST(json_extract_scalar(m,'$.requestTime') AS BIGINT)/1000),'%Y') AS INTEGER)  AS year,
  CAST(date_format(from_unixtime(CAST(json_extract_scalar(m,'$.requestTime') AS BIGINT)/1000),'%m') AS INTEGER)  AS month,
  CAST(date_format(from_unixtime(CAST(json_extract_scalar(m,'$.requestTime') AS BIGINT)/1000),'%d') AS INTEGER)  AS day,
  CAST(date_format(from_unixtime(CAST(json_extract_scalar(m,'$.requestTime') AS BIGINT)/1000),'%H') AS INTEGER)  AS hour
FROM msg;
EOF
)
SQL_CREATE_VIEW="${SQL_CREATE_VIEW//\$\{DB\}/${BILLING_GLUE_DB}}"
SQL_CREATE_VIEW="${SQL_CREATE_VIEW//\$\{VIEW\}/${BILLING_TABLE_JSON}}"
SQL_CREATE_VIEW="${SQL_CREATE_VIEW//\$\{RAW\}/${BILLING_TABLE_JSON}_raw}"

echo "[3] Create RAW table & VIEW"
aws athena start-query-execution --query-string "${SQL_CREATE_JSON_RAW}" --work-group "${BILLING_ATHENA_WORKGROUP}" >/dev/null
aws athena start-query-execution --query-string "${SQL_CREATE_VIEW}"     --work-group "${BILLING_ATHENA_WORKGROUP}" >/dev/null

echo "[4] MSCK REPAIR partitions for RAW"
aws athena start-query-execution \
  --query-string "MSCK REPAIR TABLE ${BILLING_GLUE_DB}.${BILLING_TABLE_JSON}_raw;" \
  --work-group "${BILLING_ATHENA_WORKGROUP}" >/dev/null

echo "[5] Create Parquet CTAS from VIEW"
PARQUET_LOC="s3://${BILLING_S3_BUCKET}/${BILLING_PARQUET_PREFIX:-parquet-data}"
SQL_CREATE_PARQUET=$(cat <<'EOF'
CREATE TABLE IF NOT EXISTS ${DB}.${TBL}
WITH (
  external_location = '${LOC}',
  format = 'PARQUET',
  parquet_compression = 'SNAPPY',
  partitioned_by = ARRAY['year','month','day']
) AS
SELECT
  COALESCE(NULLIF(user,''), 'anonymous') AS user,
  sub,
  httpMethod,
  path,
  routeKey,
  status,
  date_format(from_unixtime(requestTime/1000), '%Y-%m-%d') AS req_date,
  year,
  month,
  day,
  count(*) AS calls,
  sum(responseLength) AS total_bytes
FROM ${DB}.${VIEW}
GROUP BY
  COALESCE(NULLIF(user,''), 'anonymous'),
  sub, httpMethod, path, routeKey, status,
  date_format(from_unixtime(requestTime/1000), '%Y-%m-%d'),
  year, month, day;
EOF
)
SQL_CREATE_PARQUET="${SQL_CREATE_PARQUET//\$\{DB\}/${BILLING_GLUE_DB}}"
SQL_CREATE_PARQUET="${SQL_CREATE_PARQUET//\$\{TBL\}/${BILLING_TABLE_PARQUET}}"
SQL_CREATE_PARQUET="${SQL_CREATE_PARQUET//\$\{LOC\}/${PARQUET_LOC}}"
SQL_CREATE_PARQUET="${SQL_CREATE_PARQUET//\$\{VIEW\}/${BILLING_TABLE_JSON}}"

aws athena start-query-execution \
  --query-string "${SQL_CREATE_PARQUET}" \
  --work-group "${BILLING_ATHENA_WORKGROUP}" >/dev/null

echo "[OK] RAW table + VIEW + Parquet CTAS ready."
