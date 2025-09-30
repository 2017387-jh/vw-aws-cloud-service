# API Gateway 스크립트 가이드

## 개요
API Gateway는 RESTful API 엔드포인트를 제공하여 클라이언트와 백엔드 서비스(Lambda, ECS)를 연결하는 역할을 합니다. 이 문서는 API Gateway 관련 스크립트들의 상세한 설명을 제공합니다.

## 📁 관련 파일
```
script/
├── apigw_00_create_api.sh          # API Gateway 생성
├── apigw_99_cleanup.sh             # API Gateway 정리
├── apigw_51_upload_localimage.py   # 이미지 업로드 테스트
├── apigw_51_upload_localimage.sh   # 이미지 업로드 테스트 (Shell)
└── apigw_52_download_image.py      # 이미지 다운로드 테스트
```

## 🚀 apigw_00_create_api.sh

### 기능
- HTTP 타입의 API Gateway 생성
- Lambda 함수와 ALB(Application Load Balancer) 통합
- 라우트 설정 및 배포

### 주요 동작 과정

#### 1. 기존 API 확인
```bash
# 동일한 이름의 API Gateway가 존재하는지 확인
EXISTING_API_ID=$(aws apigatewayv2 get-apis \
  --query "Items[?Name=='$DDN_APIGW_NAME'].ApiId" \
  --output text)
```
- 중복 생성 방지를 위한 사전 검사
- 기존 API가 있으면 생성을 건너뛰고 종료

#### 2. API Gateway 생성
```bash
API_ID=$(aws apigatewayv2 create-api \
  --name $DDN_APIGW_NAME \
  --protocol-type HTTP \
  --query 'ApiId' \
  --output text)
```
- **프로토콜**: HTTP (REST API v2)
- **이름**: `.env`에서 정의된 `DDN_APIGW_NAME` 사용

#### 3. 통합(Integration) 설정

##### Lambda 통합 (Presigned URL 생성)
```bash
LAMBDA_INTEG_ID=$(aws apigatewayv2 create-integration \
  --api-id $API_ID \
  --integration-type AWS_PROXY \
  --integration-uri arn:aws:lambda:$AWS_REGION:$ACCOUNT_ID:function:$DDN_LAMBDA_FUNC_NAME \
  --payload-format-version 2.0 \
  --query 'IntegrationId' --output text)
```
- **타입**: `AWS_PROXY` (Lambda 프록시 통합)
- **용도**: S3 Presigned URL 생성 요청 처리
- **페이로드 버전**: 2.0 (최신 버전)

##### ALB 통합 (이미지 처리)
```bash
ALB_INTEG_ID=$(aws apigatewayv2 create-integration \
  --api-id $API_ID \
  --integration-type HTTP_PROXY \
  --integration-uri $ALB_URL \
  --integration-method ANY \
  --payload-format-version 1.0 \
  --query 'IntegrationId' --output text)
```
- **타입**: `HTTP_PROXY` (HTTP 프록시 통합)
- **용도**: ECS의 Flask 서버로 요청 전달
- **메서드**: ANY (모든 HTTP 메서드 허용)

#### 4. 라우트 생성
```bash
# Presigned URL 관련 라우트 (Lambda)
aws apigatewayv2 create-route --api-id $API_ID --route-key "GET /presign" --target integrations/$LAMBDA_INTEG_ID
aws apigatewayv2 create-route --api-id $API_ID --route-key "POST /presign" --target integrations/$LAMBDA_INTEG_ID

# 서비스 상태 확인 및 추론 요청 (ALB/ECS)
aws apigatewayv2 create-route --api-id $API_ID --route-key "GET /ping" --target integrations/$ALB_INTEG_ID
aws apigatewayv2 create-route --api-id $API_ID --route-key "POST /invocations" --target integrations/$ALB_INTEG_ID
```

**라우트 설명**:
- `GET/POST /presign`: S3 업로드/다운로드 URL 생성
- `GET /ping`: 서비스 헬스체크
- `POST /invocations`: 이미지 처리 추론 요청

#### 5. Lambda 권한 부여
```bash
aws lambda add-permission \
  --function-name $DDN_LAMBDA_FUNC_NAME \
  --statement-id apigateway-access \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com
```
- API Gateway가 Lambda 함수를 호출할 수 있는 권한 부여
- `statement-id`: 권한 정책의 고유 식별자

#### 6. 스테이지 배포
```bash
aws apigatewayv2 create-stage \
  --api-id $API_ID \
  --stage-name '$default' \
  --auto-deploy
```
- `$default` 스테이지에 자동 배포
- 변경사항 자동 반영 설정

### 환경 변수
- `DDN_APIGW_NAME`: API Gateway 이름
- `AWS_REGION`: AWS 리전
- `ACCOUNT_ID`: AWS 계정 ID
- `DDN_LAMBDA_FUNC_NAME`: Lambda 함수 이름
- `DDN_ALB_DNS`: ALB DNS 이름

---

## 🧹 apigw_99_cleanup.sh

### 기능
- 생성된 API Gateway 완전 삭제
- Lambda 권한 제거
- 리소스 정리

### 주요 동작 과정

#### 1. API 목록 조회
```bash
API_IDS=$(aws apigatewayv2 get-apis \
  --query "Items[?Name=='$DDN_APIGW_NAME'].ApiId" \
  --output text)
```
- 동일한 이름의 모든 API Gateway ID 조회
- 여러 개의 API가 있을 경우 모두 삭제

#### 2. API 삭제
```bash
for API_ID in $API_IDS; do
  echo "[INFO] Deleting API Gateway '$DDN_APIGW_NAME' (ID: $API_ID)..."
  aws apigatewayv2 delete-api --api-id "$API_ID"
done
```
- 조회된 모든 API를 순차적으로 삭제
- 스테이지, 라우트, 통합도 함께 삭제됨

#### 3. Lambda 권한 제거
```bash
set +e  # 에러 무시 모드
aws lambda remove-permission \
  --function-name "$DDN_LAMBDA_FUNC_NAME" \
  --statement-id apigateway-access
set -e  # 에러 체크 모드 재개
```
- API Gateway가 Lambda에 부여된 권한 제거
- `set +e`로 권한이 없어도 스크립트 계속 진행

---

## 🧪 apigw_51_upload_localimage.py

### 기능
- 로컬 이미지 파일을 S3에 업로드하는 테스트 스크립트
- Presigned URL을 통한 안전한 업로드 구현

### 주요 동작 과정

#### 1. 환경 설정
```python
from dotenv import load_dotenv
load_dotenv()

API_ENDPOINT = os.getenv("DDN_APIGW_ENDPOINT")
LOCAL_FILE = os.getenv("DDN_TEST_IMAGE_PATH")
S3_KEY = os.getenv("DDN_TEST_IMAGE_KEY")
```
- `.env` 파일에서 설정값 로드
- API 엔드포인트, 로컬 파일 경로, S3 키 설정

#### 2. Presigned URL 요청
```python
resp = requests.get(f"{API_ENDPOINT}/presign?mode=upload&file={S3_KEY}")
resp.raise_for_status()
upload_url = resp.json().get("url")
```
- API Gateway를 통해 Lambda 함수 호출
- `mode=upload`로 업로드용 Presigned URL 요청
- JSON 응답에서 URL 추출

#### 3. 파일 업로드
```python
with open(file_path, "rb") as f:
    r = requests.put(upload_url, data=f)
```
- 바이너리 모드로 파일 읽기
- PUT 요청으로 S3에 직접 업로드
- Presigned URL을 통한 임시 권한 사용

#### 4. 성능 측정
```python
start_time = time.perf_counter()
# ... 업로드 과정 ...
end_time = time.perf_counter()
elapsed_ms = (end_time - start_time) * 1000
```
- 업로드 시간 측정 및 리포트

### 환경 변수
- `DDN_APIGW_ENDPOINT`: API Gateway 엔드포인트 URL
- `DDN_TEST_IMAGE_PATH`: 테스트용 로컬 이미지 파일 경로
- `DDN_TEST_IMAGE_KEY`: S3에 저장될 파일의 키(경로)

---

## 🔄 apigw_52_download_image.py

### 기능
- 처리된 이미지를 S3에서 다운로드하는 테스트 스크립트
- Presigned URL을 통한 안전한 다운로드 구현

### 주요 특징
- 업로드 스크립트와 유사한 구조
- `mode=download`로 다운로드용 Presigned URL 요청
- GET 요청으로 S3에서 파일 다운로드
- 로컬 파일 시스템에 저장

---

## 🔧 사용 시나리오

### 1. 전체 API Gateway 구성
```bash
# 1. Lambda 함수가 먼저 생성되어 있어야 함
./lambda_01_create_function.sh

# 2. ECS 서비스와 ALB가 실행 중이어야 함
./ecs_05_create_service.sh

# 3. API Gateway 생성
./apigw_00_create_api.sh
```

### 2. 이미지 업로드 테스트
```bash
# Python 스크립트 사용
python apigw_51_upload_localimage.py

# 또는 Shell 스크립트 사용
./apigw_51_upload_localimage.sh
```

### 3. 이미지 다운로드 테스트
```bash
python apigw_52_download_image.py
```

### 4. API Gateway 삭제
```bash
./apigw_99_cleanup.sh
```

## ⚠️ 주의사항

1. **종속성**: Lambda 함수와 ECS 서비스가 먼저 생성되어야 함
2. **권한**: API Gateway가 Lambda를 호출할 수 있는 권한 필요
3. **네트워크**: ALB DNS가 올바르게 설정되어야 함
4. **환경 변수**: `.env` 파일의 모든 필수 변수가 설정되어야 함
5. **리전**: 모든 리소스가 동일한 리전에 있어야 함

## 🔍 트러블슈팅

### API Gateway 생성 실패
- Lambda 함수 존재 여부 확인
- IAM 권한 확인
- 리전 설정 확인

### 업로드/다운로드 실패
- S3 버킷 존재 여부 확인
- Lambda 함수의 S3 권한 확인
- 네트워크 연결 상태 확인

### ALB 통합 실패
- ALB DNS 이름 확인
- ECS 서비스 상태 확인
- 보안 그룹 설정 확인