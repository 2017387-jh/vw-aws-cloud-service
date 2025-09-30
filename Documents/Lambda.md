# Lambda 스크립트 가이드

## 개요
AWS Lambda는 서버리스 컴퓨팅 서비스로, 이 프로젝트에서는 S3 Presigned URL 생성을 위한 핵심 역할을 담당합니다. 클라이언트가 안전하게 S3에 파일을 업로드하고 다운로드할 수 있도록 임시 URL을 제공합니다.

## 📁 관련 파일
```
script/
├── lambda_function.py              # Lambda 함수 코드
├── lambda_00_prereqs.sh            # Lambda IAM 역할 생성
├── lambda_01_create_function.sh    # Lambda 함수 생성
├── lambda_51_test_invoke_upload.py # 업로드 테스트 (Python)
├── lambda_51_test_invoke_upload.sh # 업로드 테스트 (Shell)
├── lambda_52_test_invoke_download.py # 다운로드 테스트 (Python)
├── lambda_52_test_invoke_download.sh # 다운로드 테스트 (Shell)
└── lambda_99_cleanup.sh            # Lambda 리소스 정리
```

## 🎯 lambda_function.py

### 기능
- S3 Presigned URL 생성 (업로드/다운로드)
- API Gateway를 통한 RESTful 인터페이스 제공
- 안전한 임시 권한 부여

### 상세 분석

#### 1. 환경 설정 및 초기화
```python
import boto3
import json
import os
import urllib.parse

s3 = boto3.client("s3")
```
- **boto3**: AWS SDK for Python
- **S3 클라이언트**: Presigned URL 생성을 위한 S3 서비스 연결
- **전역 변수**: Lambda의 컨테이너 재사용으로 성능 최적화

#### 2. 이벤트 파라미터 처리
```python
def lambda_handler(event, context):
    params = event.get("queryStringParameters", {}) or {}
    file_name = params.get("file")
    mode = params.get("mode", "download")
```
- **API Gateway 이벤트**: HTTP 쿼리 파라미터 추출
- **필수 파라미터**: `file` (파일명/키)
- **선택 파라미터**: `mode` (upload/download, 기본값: download)

#### 3. 파라미터 검증
```python
if not file_name:
    return {"statusCode": 400, "body": "file parameter is required"}
```
- 파일명 누락 시 HTTP 400 Bad Request 반환
- 클라이언트에 명확한 오류 메시지 제공

#### 4. 버킷 및 메서드 선택
```python
if mode == "upload":
    bucket = os.environ["DDN_IN_BUCKET"]
    method = "put_object"
else:
    bucket = os.environ["DDN_OUT_BUCKET"]  
    method = "get_object"
```
- **업로드 모드**: 입력 버킷(`ddn-in-bucket`) + PUT 오퍼레이션
- **다운로드 모드**: 출력 버킷(`ddn-out-bucket`) + GET 오퍼레이션
- **환경 변수**: Lambda 환경에서 버킷명 동적 로드

#### 5. Presigned URL 생성
```python
try:
    url = s3.generate_presigned_url(
        ClientMethod=method,
        Params={"Bucket": bucket, "Key": file_name},
        ExpiresIn=3600  # 1 hour
    )
    return {"statusCode": 200, "body": json.dumps({"url": url})}
except Exception as e:
    return {"statusCode": 500, "body": "Error generating presigned URL"}
```
- **유효기간**: 3600초 (1시간)
- **반환 형식**: JSON으로 URL 래핑
- **에러 처리**: 예외 발생 시 HTTP 500 반환 (보안을 위해 상세 에러 숨김)

### 보안 고려사항
1. **임시 권한**: Presigned URL은 설정된 시간만 유효
2. **특정 오퍼레이션**: PUT 또는 GET만 가능 (전체 S3 권한 없음)
3. **에러 마스킹**: 내부 에러 정보 노출 방지

---

## 🛠️ lambda_00_prereqs.sh

### 기능
- Lambda 함수 실행을 위한 IAM 역할 생성
- S3 접근 권한 부여

### 상세 분석

#### 1. IAM 역할 생성
```bash
aws iam create-role \
  --role-name $DDN_LAMBDA_ROLE \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": { "Service": "lambda.amazonaws.com" },
        "Action": "sts:AssumeRole"
      }
    ]
  }'
```
- **역할명**: `LambdaS3AccessRole` (환경변수에서 정의)
- **신뢰 관계**: Lambda 서비스만 이 역할을 assume 가능
- **목적**: Lambda 함수가 AWS 리소스에 접근할 수 있는 권한 부여

#### 2. 관리형 정책 연결
```bash
aws iam attach-role-policy \
  --role-name $DDN_LAMBDA_ROLE \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess
```
- **정책**: `AmazonS3FullAccess`
- **권한 범위**: 모든 S3 버킷에 대한 완전한 접근
- **주의사항**: 운영 환경에서는 특정 버킷으로 권한 제한 권장

### 보안 개선 방안
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject"
      ],
      "Resource": [
        "arn:aws:s3:::ddn-in-bucket/*",
        "arn:aws:s3:::ddn-out-bucket/*"
      ]
    }
  ]
}
```
- 특정 버킷과 오퍼레이션으로 권한 제한
- 최소 권한 원칙 적용

---

## 🚀 lambda_01_create_function.sh

### 기능
- Python 코드 패키징 및 Lambda 함수 생성
- 환경변수 설정

### 상세 분석

#### 1. 코드 패키징
```bash
FUNC_ZIP_FILE="ddn_lambda_function.zip"
rm -f $FUNC_ZIP_FILE
zip $FUNC_ZIP_FILE lambda_function.py
```
- ZIP 파일로 Lambda 배포 패키지 생성
- 기존 파일 제거 후 새로 생성 (클린 패키징)

#### 2. Lambda 함수 생성
```bash
aws lambda create-function \
  --function-name $DDN_LAMBDA_FUNC_NAME \
  --runtime python3.12 \
  --role arn:aws:iam::$ACCOUNT_ID:role/$DDN_LAMBDA_ROLE \
  --handler lambda_function.lambda_handler \
  --zip-file fileb://$FUNC_ZIP_FILE \
  --environment "Variables={DDN_IN_BUCKET=$DDN_IN_BUCKET,DDN_OUT_BUCKET=$DDN_OUT_BUCKET}"
```

**파라미터 설명**:
- **function-name**: `ddn-presign-lambda`
- **runtime**: Python 3.12 (최신 버전)
- **role**: 이전 단계에서 생성한 IAM 역할
- **handler**: `파일명.함수명` 형식
- **zip-file**: `fileb://` 프리픽스로 바이너리 파일 지정
- **environment**: S3 버킷명을 환경변수로 주입

### 환경 변수
함수 실행 시 사용되는 환경변수:
- `DDN_IN_BUCKET`: 업로드용 S3 버킷
- `DDN_OUT_BUCKET`: 다운로드용 S3 버킷

---

## 🧪 lambda_51_test_invoke_upload.py

### 기능
- Lambda 함수를 통한 업로드 Presigned URL 생성 테스트
- 실제 파일 업로드 수행
- 성능 측정

### 상세 분석

#### 1. 환경 설정
```python
from dotenv import load_dotenv
load_dotenv()

lambda_name = os.getenv("DDN_LAMBDA_FUNC_NAME")
image_path = os.getenv("DDN_TEST_IMAGE_PATH")
image_key = os.getenv("DDN_TEST_IMAGE_KEY")
```
- `.env` 파일에서 테스트 설정 로드
- Lambda 함수명, 테스트 이미지 경로, S3 키 설정

#### 2. Lambda 함수 호출
```python
cmd = [
    "aws", "lambda", "invoke",
    "--function-name", lambda_name,
    "--payload", f'{{"queryStringParameters":{{"mode":"upload","file":"{image_key}"}}}}',
    "upload_response.json",
    "--region", region,
    "--cli-binary-format", "raw-in-base64-out"
]
subprocess.run(cmd, check=True)
```
- AWS CLI를 통한 Lambda 함수 직접 호출
- API Gateway 형식의 이벤트 페이로드 전달
- 응답을 JSON 파일로 저장

#### 3. 응답 처리 및 URL 추출
```python
with open("upload_response.json") as f:
    resp = json.load(f)
upload_url = json.loads(resp["body"])["url"]
```
- Lambda 응답에서 Presigned URL 추출
- 중첩된 JSON 구조 처리 (Lambda 응답 → body → url)

#### 4. 파일 업로드
```python
abs_image_path = Path(image_path).resolve()
with open(abs_image_path, "rb") as f:
    r = requests.put(upload_url, data=f)
```
- 절대 경로 변환으로 파일 접근 보장
- HTTP PUT 요청으로 S3에 직접 업로드
- `requests` 라이브러리 사용

#### 5. 성능 측정
```python
start_time = time.perf_counter()
# ... 테스트 수행 ...
end_time = time.perf_counter()
elapsed_ms = (end_time - start_time) * 1000
```
- 고해상도 시간 측정 (`perf_counter`)
- 밀리초 단위 소요 시간 계산

#### 6. 테스트 완료 처리
```python
subprocess.run([
    "aws", "s3", "cp",
    f"s3://{in_bucket}/{image_key}",
    f"s3://{out_bucket}/{image_key}",
    "--region", region
], check=True)
```
- 업로드된 파일을 출력 버킷으로 복사
- 전체 워크플로우 시뮬레이션

### 환경 변수
- `DDN_LAMBDA_FUNC_NAME`: Lambda 함수명
- `DDN_TEST_IMAGE_PATH`: 테스트용 로컬 이미지 파일 경로
- `DDN_TEST_IMAGE_KEY`: S3에 저장될 키(파일명)
- `AWS_REGION`: AWS 리전
- `DDN_IN_BUCKET`, `DDN_OUT_BUCKET`: S3 버킷명

---

## 🔄 lambda_52_test_invoke_download.py

### 기능
- Lambda 함수를 통한 다운로드 Presigned URL 생성 테스트
- S3에서 파일 다운로드 수행

### 주요 차이점
- `mode=download` 파라미터 사용
- GET 요청으로 파일 다운로드
- 로컬 파일 시스템에 저장

---

## 🧹 lambda_99_cleanup.sh

### 기능
- Lambda 함수 및 관련 IAM 리소스 완전 삭제
- 안전한 정리 순서

### 상세 분석

#### 1. Lambda 함수 삭제
```bash
aws lambda delete-function \
  --function-name $DDN_LAMBDA_FUNC_NAME \
  --region $AWS_REGION || true
```
- 함수와 모든 버전/별칭 삭제
- `|| true`로 함수가 없어도 오류 무시

#### 2. IAM 정책 분리
```bash
aws iam detach-role-policy \
  --role-name $DDN_LAMBDA_ROLE \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess || true
```
- 역할에서 관리형 정책 분리
- 분리 후 역할 삭제 가능

#### 3. IAM 역할 삭제
```bash
aws iam delete-role \
  --role-name $DDN_LAMBDA_ROLE || true
```
- 모든 정책이 분리된 후 역할 삭제
- 의존성 순서 준수

---

## 🚀 사용 시나리오

### 1. 전체 Lambda 설정
```bash
# 순서대로 실행
./lambda_00_prereqs.sh        # IAM 역할 생성
./lambda_01_create_function.sh # Lambda 함수 생성
```

### 2. 기능 테스트
```bash
# Python 스크립트 사용
python lambda_51_test_invoke_upload.py
python lambda_52_test_invoke_download.py

# 또는 Shell 스크립트 사용
./lambda_51_test_invoke_upload.sh
./lambda_52_test_invoke_download.sh
```

### 3. Lambda 함수 업데이트
```bash
# 코드 수정 후
zip ddn_lambda_function.zip lambda_function.py
aws lambda update-function-code \
  --function-name ddn-presign-lambda \
  --zip-file fileb://ddn_lambda_function.zip
```

### 4. 리소스 정리
```bash
./lambda_99_cleanup.sh
```

## 🔧 고급 설정

### 1. Lambda 함수 설정 최적화
```bash
# 메모리 및 타임아웃 조정
aws lambda update-function-configuration \
  --function-name ddn-presign-lambda \
  --memory-size 256 \
  --timeout 30
```

### 2. VPC 연결 (필요시)
```bash
aws lambda update-function-configuration \
  --function-name ddn-presign-lambda \
  --vpc-config SubnetIds=subnet-123,SecurityGroupIds=sg-456
```

### 3. 환경변수 업데이트
```bash
aws lambda update-function-configuration \
  --function-name ddn-presign-lambda \
  --environment "Variables={DDN_IN_BUCKET=new-bucket,DDN_OUT_BUCKET=new-output}"
```

## ⚠️ 주의사항

### 1. 보안
- **IAM 권한**: 최소 권한 원칙 적용 필요
- **Presigned URL**: 유효기간 설정으로 남용 방지
- **에러 로깅**: CloudWatch에서 에러 모니터링

### 2. 성능
- **콜드 스타트**: 첫 번째 호출 시 지연 시간 발생
- **동시 실행**: 높은 트래픽 시 Lambda 제한 고려
- **메모리 할당**: 코드 복잡도에 따른 적절한 메모리 설정

### 3. 비용
- **호출 횟수**: 많은 요청 시 비용 증가
- **실행 시간**: 밀리초 단위 과금
- **네트워크**: 데이터 전송 비용

## 🔍 트러블슈팅

### 1. Lambda 함수 생성 실패
```bash
# IAM 역할 확인
aws iam get-role --role-name LambdaS3AccessRole

# ZIP 파일 확인
unzip -l ddn_lambda_function.zip
```

### 2. Presigned URL 생성 실패
```bash
# Lambda 함수 로그 확인
aws logs tail /aws/lambda/ddn-presign-lambda --follow

# S3 권한 확인
aws s3 ls s3://ddn-in-bucket/
```

### 3. API Gateway 통합 문제
```bash
# Lambda 권한 확인
aws lambda get-policy --function-name ddn-presign-lambda

# API Gateway 로그 활성화
aws apigatewayv2 update-stage \
  --api-id <API_ID> \
  --stage-name '$default' \
  --access-log-settings DestinationArn=<LOG_GROUP_ARN>
```

## 📊 모니터링

### 1. CloudWatch 메트릭
- **Duration**: 함수 실행 시간
- **Invocations**: 호출 횟수
- **Errors**: 에러 발생 횟수
- **Throttles**: 제한 발생 횟수

### 2. 로그 분석
```bash
# 실시간 로그 확인
aws logs tail /aws/lambda/ddn-presign-lambda --follow

# 에러 로그 필터링
aws logs filter-log-events \
  --log-group-name /aws/lambda/ddn-presign-lambda \
  --filter-pattern "ERROR"
```

### 3. 비용 분석
- AWS Cost Explorer에서 Lambda 비용 추적
- 호출 패턴 분석을 통한 최적화 방안 도출
- Reserved Capacity 활용 검토