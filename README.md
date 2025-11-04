# VW AWS Cloud Service - Deep Denoising Platform

AWS 클라우드 기반 이미지 처리 서비스로, Triton Inference Server와 Deep Denoising 모델을 활용하여 이미지 노이즈 제거 기능을 제공합니다.

## 📋 프로젝트 개요

이 프로젝트는 AWS의 여러 서비스를 활용하여 구축된 확장 가능한 이미지 처리 플랫폼입니다:
- **ECS (Elastic Container Service)**: GPU 기반 컨테이너 실행 환경 (g4dn.xlarge)
- **Triton Inference Server**: NVIDIA의 고성능 추론 서버
- **Lambda**: S3 Presigned URL 생성을 위한 서버리스 함수
- **API Gateway**: RESTful API 엔드포인트 제공
- **Application Load Balancer**: 트래픽 분산 및 헬스체크
- **Auto Scaling**: CPU/메모리/요청 수 기반 자동 확장
- **Kinesis Firehose + Athena**: API 사용량 모니터링 및 빌링

## 🏗️ 아키텍처 구성요소

### Core Services
- **S3 Buckets**:
  - `ddn-in-bucket`: 입력 이미지 저장
  - `ddn-out-bucket`: 처리된 이미지 저장
  - `ddn-apigw-accesslog-bucket`: API 액세스 로그 저장
- **ECR Repository**: Docker 이미지 저장소 (`deepdenoising-triton`)
- **ECS Cluster**: GPU 인스턴스 (g4dn.xlarge) 기반 컨테이너 실행
- **Lambda Function**: S3 Presigned URL 생성 (`ddn-presign-lambda`)
- **API Gateway**: RESTful API 엔드포인트 (`ddn-api`)
- **Kinesis Firehose**: API 액세스 로그 수집 및 저장
- **Glue Database & Athena**: 로그 분석 및 쿼리

### Network Configuration
- **VPC**: `vpc-026400b6f5ea5c7f6`
- **Subnets**: Multi-AZ 배포 (`subnet-0b096afec739dc2a2`, `subnet-05fea229a7abfb9a8`)
- **Security Groups**: ECS 및 ALB용 보안 그룹
- **Load Balancer**: Application Load Balancer with health checks

### Container Configuration
- **Flask Server**: Port 50101 (API 서버)
- **Triton HTTP**: Port 50201 (HTTP 추론 엔드포인트)
- **Triton gRPC**: Port 58202 (gRPC 추론 엔드포인트)

## 📁 프로젝트 구조

```
vw-aws-cloud-service/
├── script/                          # 배포 및 관리 스크립트
│   ├── s3_*.sh                      # S3 버킷 관리
│   ├── ecr_*.sh                     # ECR 저장소 관리
│   ├── lambda_*.sh                  # Lambda 함수 관리
│   ├── ecs_*.sh                     # ECS 클러스터/서비스 관리
│   │   ├── ecs_10_go_all.sh         # 전체 ECS 파이프라인 자동 실행
│   │   ├── ecs_90_pause.sh          # 서비스 일시정지 (비용 절감)
│   │   └── ecs_91_resume.sh         # 서비스 재개
│   ├── apigw_*.sh                   # API Gateway 관리
│   ├── billing_*.sh                 # 빌링/로그 분석 파이프라인
│   ├── lambda_function.py           # Lambda 함수 코드
│   ├── taskdef.json.tpl             # ECS Task Definition 템플릿
│   ├── *.py                         # 테스트 및 유틸리티 스크립트
│   └── .env                         # 환경 변수 설정
├── demo_image/                      # 테스트용 샘플 이미지
├── requirements.txt                 # Python 의존성
└── README.md                        # 프로젝트 문서
```

## 🚀 시작하기

### 사전 요구사항
- AWS CLI 설정 완료
- Docker 설치
- Python 3.x 설치
- 적절한 AWS IAM 권한

### 환경 설정
1. 환경 변수 파일 준비:
   ```bash
   cp script/.env.example script/.env
   # .env 파일을 프로젝트에 맞게 수정
   ```

2. Python 의존성 설치:
   ```bash
   pip install -r requirements.txt
   ```

3. AWS CLI 설정:
   ```bash
   aws configure
   AWS Access Key ID: [your-access-key]
   Secret access key: [your-secret-key]
   Default region name: ap-northeast-2
   Default output format: json
   ```

4. Auto Scailing 최소 Taks 수
   1. .env의 DDN_ECS_DESIRED_TASK_COUNT 와 DDN_MIN_CAPACITY 수로 조정

### 배포 순서

#### 방법 1: 자동 배포 (권장)
전체 ECS 인프라를 한 번에 배포:
```bash
cd script
chmod +x ecs_10_go_all.sh
./ecs_10_go_all.sh
```

이 스크립트는 다음 단계를 자동으로 실행합니다:
- Step 0: IAM Roles 및 VPC Endpoint 설정
- Step 1: ECS Cluster 생성
- Step 2: GPU 인스턴스 Auto Scaling Group 생성
- Step 3: ALB 및 Security Group 설정
- Step 4: Task Definition 등록
- Step 5: ECS Service 생성 및 안정화 대기
- Step 6: Auto Scaling 정책 적용

#### 방법 2: 수동 배포

##### 1. 기본 인프라 구성
```bash
cd script
# S3 버킷 생성
./s3_create_bucket.sh

# ECR 저장소 생성
./ecr_create_repository.sh
```

##### 2. 컨테이너 이미지 준비
```bash
# Docker 이미지 로드 및 푸시
./ecr_load_docker_image.sh
./ecr_push_docker_image.sh
```

##### 3. Lambda 함수 배포
```bash
# Lambda 사전 요구사항 설정
./lambda_00_prereqs.sh

# Lambda 함수 생성
./lambda_01_create_function.sh
```

##### 4. API Gateway 구성
```bash
# API Gateway 생성
./apigw_00_create_api.sh
```

##### 5. ECS 서비스 배포 (개별 실행)
```bash
# ECS 사전 요구사항
./ecs_00_prereqs.sh

# 클러스터 생성
./ecs_01_create_cluster.sh

# GPU 인스턴스 Auto Scaling Group 생성
./ecs_02_capacity_gpu_asg.sh

# ALB 및 보안 그룹 설정
./ecs_03_alb_and_sg.sh

# Task Definition 등록
./ecs_04_register_taskdef.sh

# ECS 서비스 생성
./ecs_05_create_service.sh

# Auto Scaling 설정
./ecs_07_autoscaling.sh
```

##### 6. (선택사항) 빌링 파이프라인 설정
```bash
# API Gateway 액세스 로그를 Firehose -> S3 -> Athena로 전송
./billing_00_create_update_pipeline.sh
./billing_01_create_athena_tables.sh
```

## 🔧 API 엔드포인트

### API Gateway 엔드포인트
- **Base URL**: `https://cgmgt7rdl4.execute-api.ap-northeast-2.amazonaws.com`
- **Upload Presigned URL**: `GET /presign?file=<filename>&mode=upload`
- **Download Presigned URL**: `GET /presign?file=<filename>&mode=download`
- **Health Check**: `GET /ping`

### Application Load Balancer 엔드포인트
- **ALB DNS**: `ddn-alb-244774623.ap-northeast-2.elb.amazonaws.com`
- **Inference**: `POST http://<ALB-DNS>/inference`
- **Health Check**: `GET http://<ALB-DNS>/ping`
- **Invocations**: `POST http://<ALB-DNS>/invocations`

### 사용 예시

#### 1. 업로드 URL 생성
```bash
curl "https://cgmgt7rdl4.execute-api.ap-northeast-2.amazonaws.com/presign?file=test.tif&mode=upload"
```

#### 2. 이미지 업로드 및 처리
```bash
# Python 스크립트 사용
cd script
python3 apigw_51_upload_localimage.py

# 또는 직접 스크립트 실행
./apigw_51_upload_localimage.sh
```

#### 3. 처리된 이미지 다운로드
```bash
# Python 스크립트 사용
python3 apigw_52_download_image.py
```

#### 4. 헬스 체크
```bash
# API Gateway를 통한 헬스 체크
curl https://cgmgt7rdl4.execute-api.ap-northeast-2.amazonaws.com/ping

# ALB를 통한 헬스 체크
curl http://ddn-alb-244774623.ap-northeast-2.elb.amazonaws.com/ping
```

## 🧪 테스트

### Lambda 함수 테스트
```bash
cd script

# 업로드 Presigned URL 테스트
./lambda_51_test_invoke_upload.sh
# 또는
python3 lambda_51_test_invoke_upload.py

# 다운로드 Presigned URL 테스트
./lambda_52_test_invoke_download.sh
# 또는
python3 lambda_52_test_invoke_download.py
```

### 이미지 처리 E2E 테스트
```bash
cd script

# 로컬 이미지 업로드 및 처리 테스트
./apigw_51_upload_localimage.sh
# 또는
python3 apigw_51_upload_localimage.py

# 처리된 이미지 다운로드
python3 apigw_52_download_image.py
```

## 🔄 서비스 관리

### 서비스 업데이트
```bash
cd script

# ECS 서비스 업데이트 (새 이미지 배포 시)
./ecs_06_update_service.sh
```

### 비용 절감: 서비스 일시정지/재개
GPU 인스턴스 사용 시 비용 절감을 위해 사용하지 않을 때 서비스를 일시정지할 수 있습니다:

```bash
cd script

# 서비스 일시정지 (Desired Count를 0으로 설정)
./ecs_90_pause.sh

# 서비스 재개 (Desired Count를 원래대로 복구)
./ecs_91_resume.sh
```

### 리소스 정리
```bash
cd script

# ECS 리소스 전체 정리 (클러스터, 서비스, ALB 등)
./ecs_99_cleanup.sh

# Lambda 리소스 정리
./lambda_99_cleanup.sh

# API Gateway 정리
./apigw_99_cleanup.sh

# 빌링 파이프라인 정리
./billing_99_destroy_all.sh

# ALB만 삭제
./ecs_97_delete_alb.sh

# Task Definition 삭제
./ecs_98_delete_task_defs.sh
```

## 📊 모니터링 및 빌링

### 헬스체크
```bash
# ALB Health Check
curl http://ddn-alb-244774623.ap-northeast-2.elb.amazonaws.com/ping

# API Gateway Health Check
curl https://cgmgt7rdl4.execute-api.ap-northeast-2.amazonaws.com/ping
```

### 로그 확인
- **ECS Logs**: CloudWatch `/ecs/ddn-triton-task` 로그 그룹
- **Lambda Logs**: CloudWatch `/aws/lambda/ddn-presign-lambda`
- **API Gateway Logs**: CloudWatch `/aws/apigw/ddn-access-logs`

### 서비스 상태 확인
```bash
cd script
source .env

# ECS 서비스 상태 확인
aws ecs describe-services \
  --cluster $DDN_ECS_CLUSTER \
  --services $DDN_ECS_SERVICE \
  --query 'services[0].[serviceName,status,runningCount,desiredCount]' \
  --output table

# Auto Scaling 상태 확인
aws application-autoscaling describe-scalable-targets \
  --service-namespace ecs \
  --resource-ids service/$DDN_ECS_CLUSTER/$DDN_ECS_SERVICE

# ALB Target Health 확인
aws elbv2 describe-target-health \
  --target-group-arn $(aws elbv2 describe-target-groups --names $DDN_TG_FLASK --query 'TargetGroups[0].TargetGroupArn' --output text)
```

### API 사용량 분석 (Athena)
빌링 파이프라인을 설정한 경우, Athena를 통해 API 사용량을 분석할 수 있습니다:

```bash
cd script

# Athena 테이블 상태 확인
./billing_98_check_status.sh

# 일별 CTAS (Create Table As Select) 실행
./billing_02_run_daily_ctas.sh
```

Athena 콘솔에서 실행 가능한 쿼리 예시:
```sql
-- 일별 요청 수 및 상태 코드 통계
SELECT
  DATE(from_unixtime(requestTime/1000)) as date,
  httpMethod,
  routeKey,
  status,
  COUNT(*) as request_count
FROM ddn_billing_db.restapi_access_log_parquet
WHERE year = '2025' AND month = '01'
GROUP BY DATE(from_unixtime(requestTime/1000)), httpMethod, routeKey, status
ORDER BY date DESC, request_count DESC;

-- 사용자별 API 호출 통계
SELECT
  user,
  COUNT(*) as total_requests,
  SUM(CASE WHEN status = '200' THEN 1 ELSE 0 END) as success_count,
  SUM(CASE WHEN status != '200' THEN 1 ELSE 0 END) as error_count
FROM ddn_billing_db.restapi_access_log_parquet
WHERE year = '2025' AND month = '01'
GROUP BY user
ORDER BY total_requests DESC;
```

## 🛠️ 기술 스택

- **Container Runtime**: Docker
- **Inference Server**: NVIDIA Triton Inference Server
- **Web Framework**: Flask (Python)
- **Cloud Platform**: AWS
- **Compute**: ECS on EC2 (g4dn.xlarge with NVIDIA T4 GPU)
- **Storage**: Amazon S3
- **API**: AWS Lambda + API Gateway (HTTP API)
- **Load Balancing**: Application Load Balancer
- **Auto Scaling**: ECS Service Auto Scaling + EC2 Auto Scaling Group
- **Logging & Analytics**: Kinesis Data Firehose + S3 + Glue + Athena
- **IaC**: Bash scripts with AWS CLI

## 📂 주요 환경 변수

프로젝트에서 사용되는 주요 환경 변수들은 `script/.env` 파일에서 관리됩니다:

### 공통 설정
- `AWS_REGION`: AWS 리전 (ap-northeast-2)
- `ACCOUNT_ID`: AWS 계정 ID

### S3 설정
- `DDN_IN_BUCKET`: 입력 이미지 S3 버킷
- `DDN_OUT_BUCKET`: 출력 이미지 S3 버킷
- `BILLING_S3_BUCKET`: API 액세스 로그 S3 버킷

### ECR 및 이미지
- `DDN_ECR_REPO`: ECR 저장소 이름
- `DDN_ECR_TAG`: 이미지 태그
- `DDN_IMAGE_URI`: 전체 ECR 이미지 URI

### ECS 설정
- `DDN_ECS_CLUSTER`: ECS 클러스터 이름
- `DDN_ECS_SERVICE`: ECS 서비스 이름
- `DDN_ECS_TASK_FAMILY`: Task Definition 패밀리
- `DDN_ECS_INSTANCE_TYPE`: EC2 인스턴스 타입 (g4dn.xlarge)
- `DDN_ECS_DESIRED_TASK_COUNT`: 초기 태스크 수

### Auto Scaling
- `DDN_MIN_CAPACITY`: 최소 태스크 수 (기본: 1)
- `DDN_MAX_CAPACITY`: 최대 태스크 수 (기본: 4)
- `DDN_CPU_HIGH_THRESHOLD`: CPU 상한선 (기본: 80%)
- `DDN_MEMORY_HIGH_THRESHOLD`: 메모리 상한선 (기본: 80%)
- `DDN_REQUEST_COUNT_PER_TARGET`: 타겟당 요청 수 (기본: 3.0)
- `DDN_SCALE_OUT_COOLDOWN`: Scale-out 쿨다운 (기본: 60초)
- `DDN_SCALE_IN_COOLDOWN`: Scale-in 쿨다운 (기본: 60초)

### 네트워크 설정
- `DDN_VPC_ID`: VPC ID
- `DDN_SUBNET_IDS`: 서브넷 IDs (쉼표로 구분)
- `DDN_ALB_DNS`: ALB DNS 이름

### 포트 설정
- `DDN_FLASK_HTTP_PORT`: Flask HTTP 포트 (50101)
- `DDN_TRITON_HTTP_PORT`: Triton HTTP 포트 (50201)
- `DDN_TRITON_GRPC_PORT`: Triton gRPC 포트 (50202)

### Lambda 및 API Gateway
- `DDN_LAMBDA_FUNC_NAME`: Lambda 함수 이름
- `DDN_APIGW_NAME`: API Gateway 이름
- `DDN_APIGW_ENDPOINT`: API Gateway 엔드포인트 URL

### 빌링 설정
- `BILLING_FIREHOSE_NAME`: Kinesis Firehose 스트림 이름
- `BILLING_GLUE_DB`: Glue 데이터베이스 이름
- `BILLING_ATHENA_WORKGROUP`: Athena 워크그룹

## ⚠️ 주의사항

1. **비용 관리**
   - g4dn.xlarge 인스턴스는 시간당 약 $0.526 (온디맨드)의 비용 발생
   - 사용하지 않을 때는 `ecs_90_pause.sh`로 서비스를 일시정지하여 비용 절감
   - Auto Scaling 설정 시 최대 인스턴스 수를 적절히 제한

2. **보안 설정**
   - 보안 그룹: ECS와 ALB에 필요한 포트만 개방
   - IAM 역할: 최소 권한 원칙 적용
   - S3 버킷: Presigned URL을 통한 안전한 파일 업로드/다운로드

3. **리전 및 리소스 할당량**
   - 현재 리전: ap-northeast-2 (서울)
   - GPU 인스턴스 할당량 사전 확인 필요
   - 다른 리전 사용 시 `.env` 파일 수정

4. **배포 전 준비사항**
   - 스크립트 실행 권한: `chmod +x script/*.sh`
   - AWS CLI 설정 및 인증 정보 확인
   - Docker 이미지 tar 파일 준비 (`deepdenoising.triton.tar`)

5. **모니터링 및 알림**
   - CloudWatch 로그 정기 확인
   - ALB Target Health 모니터링
   - Auto Scaling 이벤트 추적
   - Athena를 통한 비용 분석 권장

6. **네트워크 구성**
   - VPC와 서브넷은 Multi-AZ 배포를 위해 최소 2개 이상 필요
   - ALB는 인터넷 연결이 필요한 경우 public 서브넷에 배포
   - ECS 태스크는 private 서브넷에 배포 권장 (NAT Gateway 필요)

## 🔧 트러블슈팅

### ECS 태스크가 시작되지 않는 경우
```bash
# 태스크 상태 확인
aws ecs describe-tasks \
  --cluster ddn-ecs-cluster \
  --tasks $(aws ecs list-tasks --cluster ddn-ecs-cluster --service-name ddn-ecs-service --query 'taskArns[0]' --output text)

# CloudWatch 로그 확인
aws logs tail /ecs/ddn-triton-task --follow
```

### ALB Health Check 실패
```bash
# Target Health 확인
aws elbv2 describe-target-health \
  --target-group-arn <TARGET_GROUP_ARN>

# 컨테이너 내부에서 헬스 체크 엔드포인트 테스트
curl http://localhost:50101/ping
```

### Auto Scaling이 작동하지 않는 경우
```bash
# Scaling Activity 확인
aws application-autoscaling describe-scaling-activities \
  --service-namespace ecs \
  --resource-id service/ddn-ecs-cluster/ddn-ecs-service
```

## 📝 라이선스

이 프로젝트는 내부 사용을 위한 것입니다.

## 🤝 기여 및 지원

문제가 발생하거나 개선 사항이 있는 경우 이슈를 등록하거나 관리자에게 문의하세요.