#!/usr/bin/env bash
set -euo pipefail
source .env
aws configure set region "${AWS_REGION}"

TODAY=$(date -u +%Y-%m-%d)
SQL=$(cat <<EOF
INSERT INTO ${BILLING_GLUE_DB}.${BILLING_TABLE_PARQUET}
SELECT user, sub, httpMethod, resourcePath, status,
       date_format(from_unixtime(requestTime/1000), '%Y-%m-%d') AS req_date,
       year(from_unixtime(requestTime/1000))  AS year,
       month(from_unixtime(requestTime/1000)) AS month,
       day(from_unixtime(requestTime/1000))   AS day,
       count(*) AS calls, sum(responseLength) AS total_bytes
FROM ${BILLING_GLUE_DB}.${BILLING_TABLE_JSON}
WHERE date_format(from_unixtime(requestTime/1000), '%Y-%m-%d')='${TODAY}'
GROUP BY user, sub, httpMethod, resourcePath, status,
         date_format(from_unixtime(requestTime/1000), '%Y-%m-%d'),
         year(from_unixtime(requestTime/1000)),
         month(from_unixtime(requestTime/1000)),
         day(from_unixtime(requestTime/1000));
EOF
)
aws athena start-query-execution --query-string "${SQL}" --work-group "${BILLING_ATHENA_WORKGROUP}" >/dev/null
echo "[OK] Daily aggregation appended for ${TODAY}"
