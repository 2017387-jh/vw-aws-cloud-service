# API Gateway Billing Pipeline Documentation

## 개요

이 문서는 API Gateway의 액세스 로그를 수집하고, S3에 저장하며, Athena를 통해 쿼리할 수 있도록 구성하는 두 개의 스크립트에 대한 설명입니다. 이 파이프라인을 통해 API 사용량을 추적하고 향후 요금 청구에 활용할 수 있습니다.

## 아키텍처 다이어그램

```
API Gateway (ddn-api)
    │
    ├─> CloudWatch Logs (/aws/apigw/ddn-access-logs)
    │       │
    │       └─> Subscription Filter (ToFirehose)
    │               │
    │               └─> Kinesis Firehose (ddn-apigw-accesslog-fh)
    │                       │
    │                       ├─> S3 Bucket (ddn-apigw-accesslog-bucket)
    │                       │   └─> json-data/year=YYYY/month=MM/day=DD/hour=HH/
    │                       │
    │                       └─> CloudWatch Logs (/aws/kinesisfirehose/...)
    │
    └─> Athena (BillingWG workgroup)
            │
            ├─> Glue Database (ddn_billing_db)
            │   ├─> Table: restapi_access_log_json_raw
            │   ├─> View: restapi_access_log_json
            │   └─> Table: restapi_access_log_parquet
            │
            └─> Query Results → S3
```

---

## 스크립트 1: billing_00_create_update_pipeline.sh

### 목적
API Gateway 액세스 로그를 CloudWatch Logs를 통해 Kinesis Firehose로 전송하고, S3에 저장하는 전체 파이프라인을 구축합니다.

### 주요 단계

#### [0] Pre-check: IAM PassRole 권한 확인
```bash
PASS_DECISION=$(aws iam simulate-principal-policy ...)
```
- 현재 사용자가 Firehose에 IAM role을 전달할 수 있는지 검증
- `iam:PassRole` 권한이 없으면 스크립트 실행 중단
- 보안 정책 준수를 위한 사전 검증

#### [1] S3 버킷 생성
```bash
BILLING_S3_BUCKET=ddn-apigw-accesslog-bucket
```
- 액세스 로그를 저장할 S3 버킷 생성 또는 확인
- 이미 존재하면 스킵
- Region: `ap-northeast-2`

#### [2] Firehose용 IAM Role 및 Policy 생성
**생성되는 리소스:**
- **Role**: `ddn-apigw-accesslog-fh-role`
- **Policy**: `ddn-apigw-accesslog-fh-policy`

**권한:**
- S3: `PutObject`, `GetObject`, `ListBucket` 등
- CloudWatch Logs: `CreateLogGroup`, `PutLogEvents` 등

**Trust Relationship:**
```json
{
  "Principal": {"Service": "firehose.amazonaws.com"},
  "Action": "sts:AssumeRole"
}
```

**[2.1] S3 버킷 정책 추가:**
- Firehose role이 S3 버킷에 데이터를 쓸 수 있도록 버킷 정책 설정
- `json-data/*` 및 `error/*` 경로에 대한 `PutObject` 권한 부여
- Role 전파 지연을 고려한 재시도 로직 (최대 6회, 5초 간격)

#### [3] Kinesis Firehose 생성/업데이트
**Delivery Stream 이름**: `ddn-apigw-accesslog-fh`

**설정:**
- **BufferingHints**: 60초 또는 1MB마다 S3에 전송 (빠른 버퍼링)
- **CompressionFormat**: `UNCOMPRESSED` (CloudWatch Logs가 이미 GZIP 압축하므로 이중 압축 방지)
- **Prefix**: `json-data/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/hour=!{timestamp:HH}/`
- **ErrorOutputPrefix**: `error/!{timestamp:yyyy}/!{timestamp:MM}/!{timestamp:dd}/!{timestamp:HH}/`

**중요:** CloudWatch Logs subscription filter는 자동으로 GZIP 압축을 수행합니다. 따라서 Firehose에서 `UNCOMPRESSED`로 설정해도 S3에 저장되는 파일은 여전히 GZIP 압축되어 있습니다. 이는 AWS의 기본 동작이며 변경할 수 없습니다. Athena는 GZIP 파일을 자동으로 읽을 수 있습니다.

**[3.0] Firehose 로깅 설정:**
- CloudWatch Log Group 생성: `/aws/kinesisfirehose/ddn-apigw-accesslog-fh`
- 보존 기간: 14일

**[3.1] Firehose 상태 확인:**
- 최대 30회 재시도 (5초 간격)
- `ACTIVE` 상태가 될 때까지 대기

#### [4] CloudWatch Logs 그룹 생성
**Log Group**: `/aws/apigw/ddn-access-logs`
- API Gateway 액세스 로그가 기록될 CloudWatch Logs 그룹 생성
- 보존 기간: 30일

#### [5] CloudWatch Logs Resource Policy 설정
- CloudWatch Logs 서비스가 Subscription Filter를 생성할 수 있도록 리소스 정책 추가
- 선택적 단계 (Optional)

#### [6] Logs → Firehose Subscription 구성

**[6.1] 기존 Subscription Filter 삭제:**
- 중복 방지를 위해 기존 필터 제거

**[6.2] IAM Role 생성:**
- **Role**: `ddn-apigw-accesslog-fh-logs-to-fh-role`
- **Policy**: `ddn-apigw-accesslog-fh-logs-to-fh-policy`
- **권한**: `firehose:PutRecord`, `firehose:PutRecordBatch`
- **Trust Relationship**: `logs.ap-northeast-2.amazonaws.com`

**[6.3] Subscription Filter 생성:**
```bash
aws logs put-subscription-filter \
  --log-group-name "/aws/apigw/ddn-access-logs" \
  --filter-name "ToFirehose" \
  --filter-pattern "" \
  --destination-arn "arn:aws:firehose:...:deliverystream/ddn-apigw-accesslog-fh" \
  --role-arn "arn:aws:iam::...:role/ddn-apigw-accesslog-fh-logs-to-fh-role"
```
- 모든 로그 (`filter-pattern ""`)를 Firehose로 전송
- 재시도 로직 포함 (최대 5회)

**[6.4] 검증:**
- Subscription Filter가 정상적으로 연결되었는지 확인
- Firehose 진단 로그 확인 (최근 5분)

#### [7] API Gateway 액세스 로깅 활성화
```bash
API_ID=$(aws apigatewayv2 get-apis --query "Items[?Name=='ddn-api'].ApiId")
```
- API Gateway (`ddn-api`)의 `$default` 스테이지에 액세스 로깅 설정
- 로그 포맷:
```json
{
  "requestId": "$context.requestId",
  "ip": "$context.identity.sourceIp",
  "user": "$context.authorizer.claims.cognito:username",
  "sub": "$context.authorizer.claims.sub",
  "requestTime": $context.requestTimeEpoch,
  "httpMethod": "$context.httpMethod",
  "routeKey": "$context.routeKey",
  "path": "$context.path",
  "status": "$context.status",
  "protocol": "$context.protocol",
  "responseLength": $context.responseLength
}
```

### 데이터 흐름 상세

1. **API Gateway** → 요청 수신
2. **CloudWatch Logs** → 로그 기록 (`/aws/apigw/ddn-access-logs`)
3. **Subscription Filter** → CloudWatch Logs 형식으로 래핑:
   ```json
   {
     "messageType": "DATA_MESSAGE",
     "logEvents": [
       {
         "id": "...",
         "timestamp": 1761002943455,
         "message": "{\"requestId\":\"...\",\"ip\":\"...\", ...}"
       }
     ]
   }
   ```
4. **Kinesis Firehose** → 60초 또는 1MB마다 배치 처리
5. **S3** → GZIP 압축하여 저장 (`json-data/year=2025/month=10/day=21/hour=08/...gz`)

### 실행 방법
```bash
cd script
./billing_00_create_update_pipeline.sh
```

### 예상 실행 시간
- 약 1-2분 (IAM role 전파 대기 시간 포함)

---

## 스크립트 2: billing_01_create_athena_tables.sh

### 목적
S3에 저장된 로그 데이터를 Athena를 통해 쿼리할 수 있도록 Glue 데이터베이스, 테이블, 뷰를 생성합니다.

### 주요 단계

#### [1] Athena Workgroup 생성
```bash
BILLING_ATHENA_WORKGROUP=BillingWG
```
- 쿼리 결과 저장 위치: `s3://ddn-apigw-accesslog-bucket/athena-results/`
- 이미 존재하면 스킵

#### [2] Glue Database 생성
```bash
BILLING_GLUE_DB=ddn_billing_db
```
- Athena 테이블의 논리적 컨테이너
- 이미 존재하면 스킵

#### [3] 테이블 및 뷰 생성

##### [3.1] Raw 테이블: `restapi_access_log_json_raw`

**목적**: CloudWatch Logs Subscription Filter 형식의 원본 데이터 저장

**스키마:**
```sql
CREATE EXTERNAL TABLE restapi_access_log_json_raw(
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
LOCATION 's3://ddn-apigw-accesslog-bucket/json-data'
```

**특징:**
- `logEvents` 배열 내부에 실제 로그가 `message` 필드에 JSON 문자열로 저장됨
- Partition 키: `year`, `month`, `day`, `hour` (S3 경로와 매칭)

##### [3.2] 뷰: `restapi_access_log_json`

**목적**: `logEvents[].message`의 JSON을 파싱하여 사용하기 쉬운 형태로 제공

**스키마:**
```sql
CREATE OR REPLACE VIEW restapi_access_log_json AS
SELECT
  json_extract_scalar(log.message, '$.requestId') AS requestId,
  json_extract_scalar(log.message, '$.ip') AS ip,
  json_extract_scalar(log.message, '$.user') AS user,
  json_extract_scalar(log.message, '$.sub') AS sub,
  CAST(json_extract_scalar(log.message, '$.requestTime') AS bigint) AS requestTime,
  json_extract_scalar(log.message, '$.httpMethod') AS httpMethod,
  json_extract_scalar(log.message, '$.path') AS path,
  json_extract_scalar(log.message, '$.routeKey') AS routeKey,
  json_extract_scalar(log.message, '$.status') AS status,
  json_extract_scalar(log.message, '$.protocol') AS protocol,
  CAST(json_extract_scalar(log.message, '$.responseLength') AS bigint) AS responseLength,
  raw.year, raw.month, raw.day, raw.hour
FROM restapi_access_log_json_raw raw
CROSS JOIN UNNEST(raw.logEvents) AS t(log)
```

**특징:**
- `UNNEST(logEvents)`: 배열을 행으로 변환
- `json_extract_scalar()`: JSON 문자열에서 필드 추출
- 기존 쿼리와 동일하게 사용 가능

#### [4] Partition 로딩 (MSCK REPAIR)
```sql
MSCK REPAIR TABLE restapi_access_log_json_raw;
```
- S3의 파티션 경로를 스캔하여 Glue Catalog에 등록
- 새로운 데이터가 추가될 때마다 실행 필요 (또는 자동화)

#### [5] Parquet 집계 테이블 생성 (Optional)
**테이블 이름**: `restapi_access_log_parquet`

**목적**: 일일 집계 데이터를 Parquet 형식으로 저장하여 쿼리 성능 향상

**CTAS (Create Table As Select):**
```sql
CREATE TABLE restapi_access_log_parquet
WITH (
  format = 'PARQUET',
  parquet_compression = 'SNAPPY',
  partitioned_by = ARRAY['year','month','day']
) AS
SELECT
  user, sub, httpMethod, path, routeKey, status,
  date_format(from_unixtime(requestTime/1000), '%Y-%m-%d') AS req_date,
  year(from_unixtime(requestTime/1000)) AS year,
  month(from_unixtime(requestTime/1000)) AS month,
  day(from_unixtime(requestTime/1000)) AS day,
  count(*) AS calls,
  sum(responseLength) AS total_bytes
FROM restapi_access_log_json
GROUP BY user, sub, httpMethod, path, routeKey, status, ...
```

**특징:**
- 사용자별/경로별 일일 집계
- Parquet + Snappy 압축으로 저장 공간 최적화
- 쿼리 속도 향상 (특히 큰 데이터셋)

### 실행 방법
```bash
cd script
./billing_01_create_athena_tables.sh
```

### 예상 실행 시간
- 약 10-30초

---

## Athena 쿼리 예제

### 1. Raw 데이터 확인
```sql
SELECT *
FROM ddn_billing_db.restapi_access_log_json_raw
LIMIT 5;
```

### 2. 파싱된 로그 조회
```sql
SELECT
  requestId,
  ip,
  user,
  httpMethod,
  routeKey,
  status,
  responseLength,
  from_unixtime(requestTime) AS request_timestamp
FROM ddn_billing_db.restapi_access_log_json
WHERE year = 2025 AND month = 10 AND day = 21
ORDER BY requestTime DESC
LIMIT 10;
```

### 3. 사용자별 일일 API 호출 통계
```sql
SELECT
  user,
  sub,
  routeKey,
  DATE(from_unixtime(requestTime)) AS date,
  COUNT(*) AS total_calls,
  SUM(responseLength) AS total_bytes,
  SUM(responseLength) / 1024.0 / 1024.0 AS total_mb
FROM ddn_billing_db.restapi_access_log_json
WHERE user != '-:username'  -- 인증되지 않은 요청 제외
GROUP BY user, sub, routeKey, DATE(from_unixtime(requestTime))
ORDER BY date DESC, total_calls DESC;
```

### 4. 시간대별 트래픽 분석
```sql
SELECT
  year, month, day, hour,
  COUNT(*) AS request_count,
  SUM(responseLength) / 1024.0 / 1024.0 AS total_mb,
  AVG(responseLength) AS avg_response_size
FROM ddn_billing_db.restapi_access_log_json
GROUP BY year, month, day, hour
ORDER BY year DESC, month DESC, day DESC, hour DESC;
```

### 5. 경로별 에러율 분석
```sql
SELECT
  routeKey,
  COUNT(*) AS total_requests,
  SUM(CASE WHEN status LIKE '2%' THEN 1 ELSE 0 END) AS success_count,
  SUM(CASE WHEN status LIKE '4%' OR status LIKE '5%' THEN 1 ELSE 0 END) AS error_count,
  CAST(SUM(CASE WHEN status LIKE '4%' OR status LIKE '5%' THEN 1 ELSE 0 END) AS DOUBLE)
    / COUNT(*) * 100 AS error_rate_percent
FROM ddn_billing_db.restapi_access_log_json
WHERE year = 2025 AND month = 10
GROUP BY routeKey
ORDER BY error_rate_percent DESC;
```

### 6. Parquet 집계 테이블 조회 (빠른 쿼리)
```sql
SELECT
  user,
  routeKey,
  req_date,
  calls,
  total_bytes / 1024.0 / 1024.0 AS total_mb
FROM ddn_billing_db.restapi_access_log_parquet
WHERE year = 2025 AND month = 10
ORDER BY req_date DESC, calls DESC;
```

---

## 요금 청구 시나리오

### 사용량 기반 요금 계산 예시

```sql
-- 월별 사용자당 API 호출 횟수 및 데이터 전송량
SELECT
  user,
  sub,
  COUNT(*) AS monthly_calls,
  SUM(responseLength) / 1024.0 / 1024.0 / 1024.0 AS total_gb,
  -- 요금 계산 예시 (가정: 호출당 $0.001, GB당 $0.10)
  COUNT(*) * 0.001 AS call_charges_usd,
  (SUM(responseLength) / 1024.0 / 1024.0 / 1024.0) * 0.10 AS data_charges_usd,
  COUNT(*) * 0.001 + (SUM(responseLength) / 1024.0 / 1024.0 / 1024.0) * 0.10 AS total_charges_usd
FROM ddn_billing_db.restapi_access_log_json
WHERE year = 2025 AND month = 10
  AND user != '-:username'
GROUP BY user, sub
ORDER BY total_charges_usd DESC;
```

---

## 운영 가이드

### 정기 작업

#### 1. 파티션 갱신 (일 1회 권장)
```bash
aws athena start-query-execution \
  --query-string "MSCK REPAIR TABLE ddn_billing_db.restapi_access_log_json_raw;" \
  --work-group "BillingWG"
```

#### 2. Parquet 집계 테이블 갱신 (일 1회)
```sql
-- 기존 데이터 삭제 후 재생성
DROP TABLE IF EXISTS ddn_billing_db.restapi_access_log_parquet;

-- CTAS 재실행
CREATE TABLE ddn_billing_db.restapi_access_log_parquet
WITH (format = 'PARQUET', ...) AS
SELECT ... FROM ddn_billing_db.restapi_access_log_json ...
```

### 모니터링

#### Firehose 상태 확인
```bash
aws firehose describe-delivery-stream \
  --delivery-stream-name "ddn-apigw-accesslog-fh" \
  --query 'DeliveryStreamDescription.DeliveryStreamStatus'
```

#### Subscription Filter 상태 확인
```bash
aws logs describe-subscription-filters \
  --log-group-name "/aws/apigw/ddn-access-logs"
```

#### S3 데이터 확인
```bash
aws s3 ls s3://ddn-apigw-accesslog-bucket/json-data/ --recursive --human-readable
```

### 트러블슈팅

#### 문제 1: Athena 쿼리 결과가 비어있음
**원인**: 파티션이 로드되지 않음
**해결**:
```sql
MSCK REPAIR TABLE ddn_billing_db.restapi_access_log_json_raw;
```

#### 문제 2: Firehose가 S3에 데이터를 쓰지 못함
**원인**: IAM 권한 또는 버킷 정책 문제
**해결**:
1. Firehose CloudWatch Logs 확인:
   ```bash
   aws logs filter-log-events \
     --log-group-name "/aws/kinesisfirehose/ddn-apigw-accesslog-fh" \
     --start-time $(($(date +%s - 3600) * 1000))
   ```
2. IAM role 권한 확인:
   ```bash
   aws iam get-role-policy --role-name "ddn-apigw-accesslog-fh-role" \
     --policy-name "ddn-apigw-accesslog-fh-policy"
   ```

#### 문제 3: API Gateway 로그가 CloudWatch에 기록되지 않음
**원인**: 액세스 로깅 미설정
**해결**:
```bash
# billing_00_create_update_pipeline.sh 재실행
cd script
./billing_00_create_update_pipeline.sh
```

---

## 비용 최적화

### 1. S3 Lifecycle 정책
```json
{
  "Rules": [
    {
      "Id": "ArchiveOldLogs",
      "Status": "Enabled",
      "Transitions": [
        {
          "Days": 90,
          "StorageClass": "GLACIER"
        }
      ],
      "Expiration": {
        "Days": 365
      }
    }
  ]
}
```

### 2. CloudWatch Logs 보존 기간
- API Gateway 로그: 30일 (현재 설정)
- Firehose 로그: 14일 (현재 설정)

### 3. Parquet 변환
- JSON보다 80% 저장 공간 절약
- Athena 스캔 비용 감소 (컬럼형 포맷)

---

## 환경 변수 (.env)

스크립트에서 사용하는 주요 환경 변수:

```bash
# Billing 관련
BILLING_FIREHOSE_NAME=ddn-apigw-accesslog-fh
BILLING_S3_BUCKET=ddn-apigw-accesslog-bucket
BILLING_S3_PREFIX=json-data/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/hour=!{timestamp:HH}/
BILLING_S3_ERROR_PREFIX=error/!{timestamp:yyyy}/!{timestamp:MM}/!{timestamp:dd}/!{timestamp:HH}/!{firehose:error-output-type}
BILLING_GLUE_DB=ddn_billing_db
BILLING_ATHENA_WORKGROUP=BillingWG
BILLING_TABLE_JSON=restapi_access_log_json
BILLING_TABLE_PARQUET=restapi_access_log_parquet
BILLING_PARQUET_PREFIX=parquet-data/
BILLING_LOG_GROUP=/aws/apigw/ddn-access-logs
BILLING_LOG_FORMAT='{"requestId":"$context.requestId","ip":"$context.identity.sourceIp",...}'
```

---

## 결론

이 파이프라인을 통해:
1. API Gateway의 모든 요청이 실시간으로 추적됩니다
2. 데이터는 안전하게 S3에 저장되며 Athena로 쿼리 가능합니다
3. 사용자별/경로별 사용량을 분석하여 요금을 부과할 수 있습니다
4. 확장 가능하고 비용 효율적인 아키텍처입니다

추가 질문이나 개선 사항이 있다면 언제든지 문의하세요!
