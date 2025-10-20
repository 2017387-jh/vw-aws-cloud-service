#!/usr/bin/env bash
set -euo pipefail
source .env
aws configure set region "${AWS_REGION}"

TODAY=$(date -u +%Y-%m-%d)

SQL=$(cat <<EOF
INSERT INTO ${BILLING_GLUE_DB}.${BILLING_TABLE_PARQUET}
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
FROM ${BILLING_GLUE_DB}.${BILLING_TABLE_JSON}   -- 뷰를 사용
WHERE date_format(from_unixtime(requestTime/1000), '%Y-%m-%d')='${TODAY}'
GROUP BY
  COALESCE(NULLIF(user,''), 'anonymous'),
  sub, httpMethod, path, routeKey, status,
  year, month, day,
  date_format(from_unixtime(requestTime/1000), '%Y-%m-%d');
EOF
)

aws athena start-query-execution \
  --query-string "${SQL}" \
  --work-group "${BILLING_ATHENA_WORKGROUP}" >/dev/null

echo "[OK] Daily aggregation appended for ${TODAY}"
