#!/usr/bin/env bash
set -euo pipefail
source .env
aws configure set region "${AWS_REGION}"

DB="${BILLING_GLUE_DB}"
VIEW="${BILLING_GLUE_DB}.${BILLING_TABLE_JSON}"
TBL="${BILLING_GLUE_DB}.${BILLING_TABLE_PARQUET}"
WG="${BILLING_ATHENA_WORKGROUP}"

# UTC 기준 오늘 (Firehose 파티션이 UTC이므로 유지)
TODAY_UTC=$(date -u +%Y-%m-%d)
Y=$(date -u +%Y)
M=$(date -u +%-m)   # no leading zero for partition ints
D=$(date -u +%-d)

wait_for_query() {
  local qid="$1" desc="${2:-Query}"
  echo "  → Waiting for ${desc} (QueryExecutionId=${qid})..."
  for i in {1..180}; do
    local s
    s=$(aws athena get-query-execution --query-execution-id "$qid" --query 'QueryExecution.Status.State' --output text || true)
    case "$s" in
      SUCCEEDED) echo "  ✓ ${desc} SUCCEEDED"; return 0 ;;
      FAILED|CANCELLED)
        echo "  ✗ ${desc} ${s}"
        aws athena get-query-execution --query-execution-id "$qid" --output json | jq -r '.QueryExecution.Status.StateChangeReason' || true
        return 1 ;;
      RUNNING|QUEUED|SUBMITTED|"") sleep 1 ;;
    esac
  done
  echo "  ✗ ${desc} timed out"
  return 1
}

run_query() {
  local sql="$1" desc="$2"
  local qid
  if ! qid=$(
    aws athena start-query-execution \
      --work-group "$WG" \
      --query-string "$sql" \
      --query 'QueryExecutionId' --output text 2>/tmp/athena_start.err
  ); then
    echo "  ✗ ${desc} FAILED to start"; cat /tmp/athena_start.err || true; return 1
  fi
  if [[ -z "$qid" || "$qid" == "None" ]]; then
    echo "  ✗ ${desc} returned empty QueryExecutionId"; cat /tmp/athena_start.err || true; return 1
  fi
  wait_for_query "$qid" "$desc"
}

echo "[1] Check if Parquet table exists: ${TBL}"
if aws glue get-table --database-name "$DB" --name "${BILLING_TABLE_PARQUET}" >/dev/null 2>&1; then
  echo "  ✓ Table exists. Will refresh partition for ${TODAY_UTC} (year=$Y, month=$M, day=$D)."

  # 1) 해당 날짜 파티션 드롭(있으면)
  SQL_DROP_PARTITION=$(cat <<EOF
ALTER TABLE ${TBL}
DROP IF EXISTS PARTITION (year=${Y}, month=${M}, day=${D});
EOF
)
  run_query "${SQL_DROP_PARTITION}" "Drop existing partition ${Y}-${M}-${D}" || true

  # 2) Insert 오늘 데이터
  SQL_INSERT=$(cat <<EOF
INSERT INTO ${TBL}
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
  COUNT(*) AS calls,
  SUM(responseLength) AS total_bytes
FROM ${VIEW}
WHERE date_format(from_unixtime(requestTime/1000), '%Y-%m-%d')='${TODAY_UTC}'
GROUP BY
  COALESCE(NULLIF(user,''), 'anonymous'),
  sub, httpMethod, path, routeKey, status,
  year, month, day,
  date_format(from_unixtime(requestTime/1000), '%Y-%m-%d');
EOF
)
  run_query "${SQL_INSERT}" "Daily INSERT for ${TODAY_UTC}"

else
  echo "  • Table not found. Creating with CTAS for ${TODAY_UTC} (initial load)."

  # 최초 1회: CTAS (WorkGroup Enforce와 호환 → external_location 미지정)
  SQL_CTAS=$(cat <<EOF
CREATE TABLE ${TBL}
WITH (
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
  COUNT(*) AS calls,
  SUM(responseLength) AS total_bytes
FROM ${VIEW}
WHERE date_format(from_unixtime(requestTime/1000), '%Y-%m-%d')='${TODAY_UTC}'
GROUP BY
  COALESCE(NULLIF(user,''), 'anonymous'),
  sub, httpMethod, path, routeKey, status,
  year, month, day,
  date_format(from_unixtime(requestTime/1000), '%Y-%m-%d');
EOF
)
  run_query "${SQL_CTAS}" "CTAS create ${TBL}"
fi

echo "[OK] Daily aggregation done for ${TODAY_UTC}"
