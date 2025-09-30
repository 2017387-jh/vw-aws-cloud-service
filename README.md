# VW AWS Cloud Service - Deep Denoising Platform

AWS 클라우드 기반 이미지 처리 서비스로, Triton Inference Server와 Deep Denoising 모델을 활용하여 이미지 노이즈 제거 기능을 제공합니다.

## 📋 프로젝트 개요

이 프로젝트는 AWS의 여러 서비스를 활용하여 구축된 이미지 처리 플랫폼입니다:
- **ECS (Elastic Container Service)**: GPU 기반 컨테이너 실행 환경
- **Triton Inference Server**: NVIDIA의 고성능 추론 서버
- **Lambda**: S3 Presigned URL 생성을 위한 서버리스 함수
- **API Gateway**: RESTful API 엔드포인트 제공
- **Application Load Balancer**: 트래픽 분산 및 헬스체크

## 🏗️ 아키텍처 구성요소

### Core Services
- **S3 Buckets**: 
  - `ddn-in-bucket`: 입력 이미지 저장
  - `ddn-out-bucket`: 처리된 이미지 저장
- **ECR Repository**: Docker 이미지 저장소 (`deepdenoising-triton`)
- **ECS Cluster**: GPU 인스턴스 (g4dn.xlarge) 기반 컨테이너 실행
- **Lambda Function**: S3 Presigned URL 생성 (`ddn-presign-lambda`)
- **API Gateway**: RESTful API 엔드포인트 (`ddn-presign-api`)

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
│   ├── apigw_*.sh                   # API Gateway 관리
│   ├── lambda_function.py           # Lambda 함수 코드
│   ├── taskdef.json.tpl             # ECS Task Definition 템플릿
│   └── test scripts                 # 테스트 스크립트들
├── demo_image/                      # 테스트용 샘플 이미지
├── requirements.txt                 # Python 의존성
├── .env                            # 환경 변수 설정
└── README.md                       # 프로젝트 문서
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

### 배포 순서

#### 1. 기본 인프라 구성
```bash
# S3 버킷 생성
./script/s3_create_bucket.sh

# ECR 저장소 생성
./script/ecr_create_repository.sh
```

#### 2. 컨테이너 이미지 준비
```bash
# Docker 이미지 로드 및 푸시
./script/ecr_load_docker_image.sh
./script/ecr_push_docker_image.sh
```

#### 3. Lambda 함수 배포
```bash
# Lambda 사전 요구사항 설정
./script/lambda_00_prereqs.sh

# Lambda 함수 생성
./script/lambda_01_create_function.sh
```

#### 4. API Gateway 구성
```bash
# API Gateway 생성
./script/apigw_00_create_api.sh
```

#### 5. ECS 서비스 배포
```bash
# ECS 사전 요구사항
./script/ecs_00_prereqs.sh

# 클러스터 생성
./script/ecs_01_create_cluster.sh

# GPU 인스턴스 Auto Scaling Group 생성
./script/ecs_02_capacity_gpu_asg.sh

# ALB 및 보안 그룹 설정
./script/ecs_03_alb_and_sg.sh

# Task Definition 등록
./script/ecs_04_register_taskdef.sh

# ECS 서비스 생성
./script/ecs_05_create_service.sh

# (선택사항) Auto Scaling 설정
./script/ecs_07_autoscaling.sh
```

## 🔧 API 엔드포인트

### API Gateway 엔드포인트
- **Base URL**: `https://61ds4ms3oh.execute-api.ap-northeast-2.amazonaws.com`
- **Upload Presigned URL**: `GET /presign?file=<filename>&mode=upload`
- **Download Presigned URL**: `GET /presign?file=<filename>&mode=download`
- **Inference**: `POST /inference` (via ALB)
- **Health Check**: `GET /ping`

### 사용 예시

#### 1. 업로드 URL 생성
```bash
curl "https://61ds4ms3oh.execute-api.ap-northeast-2.amazonaws.com/presign?file=test.tif&mode=upload"
```

#### 2. 이미지 업로드
```python
# apigw_51_upload_localimage.py 참조
import requests
response = requests.get(presign_url)
upload_url = response.json()['url']
# PUT 요청으로 이미지 업로드
```

#### 3. 처리된 이미지 다운로드
```python
# apigw_52_download_image.py 참조
response = requests.get(download_presign_url)
download_url = response.json()['url']
# GET 요청으로 이미지 다운로드
```

## 🧪 테스트

### Lambda 함수 테스트
```bash
# 업로드 테스트
./script/lambda_51_test_invoke_upload.sh

# 다운로드 테스트  
./script/lambda_52_test_invoke_download.sh
```

### 이미지 처리 테스트
```bash
# 로컬 이미지 업로드 테스트
./script/apigw_51_upload_localimage.sh

# 처리된 이미지 다운로드 테스트
./script/apigw_52_download_image.py
```

## 🔄 서비스 관리

### 서비스 업데이트
```bash
# ECS 서비스 업데이트 (새 이미지 배포 시)
./script/ecs_06_update_service.sh
```

### 리소스 정리
```bash
# 전체 ECS 리소스 정리
./script/ecs_99_cleanup.sh

# Lambda 리소스 정리
./script/lambda_99_cleanup.sh

# API Gateway 정리
./script/apigw_99_cleanup.sh
```

## 📊 모니터링

### 헬스체크
- **ALB Health Check**: `/healthz` (Flask 서버)
- **Triton Health**: Triton 서버 자체 헬스체크

### 로그 확인
- **ECS Logs**: CloudWatch `/ecs/ddn-triton-task` 로그 그룹
- **Lambda Logs**: CloudWatch `/aws/lambda/ddn-presign-lambda`

## 🛠️ 기술 스택

- **Container Runtime**: Docker
- **Inference Server**: NVIDIA Triton Inference Server
- **Web Framework**: Flask (Python)
- **Cloud Platform**: AWS
- **Compute**: ECS on EC2 (GPU instances)
- **Storage**: Amazon S3
- **API**: AWS Lambda + API Gateway
- **Load Balancing**: Application Load Balancer

## 📂 주요 환경 변수

프로젝트에서 사용되는 주요 환경 변수들은 `script/.env` 파일에서 관리됩니다:

- `AWS_REGION`: AWS 리전 (ap-northeast-2)
- `ACCOUNT_ID`: AWS 계정 ID
- `DDN_IN_BUCKET`: 입력 이미지 S3 버킷
- `DDN_OUT_BUCKET`: 출력 이미지 S3 버킷
- `DDN_ECR_REPO`: ECR 저장소 이름
- `DDN_ECS_CLUSTER`: ECS 클러스터 이름
- `DDN_LAMBDA_FUNC_NAME`: Lambda 함수 이름

## ⚠️ 주의사항

1. **비용**: g4dn.xlarge 인스턴스 사용으로 인한 높은 비용
2. **보안**: 보안 그룹 및 IAM 역할 적절히 설정 필요
3. **리전**: 현재 ap-northeast-2 (서울) 리전으로 설정됨
4. **GPU 리소스**: GPU 할당량 확인 필요
5. **권한 설정**: 배포 스크립트 실행 전 `chmod +x` 로 실행 권한 부여 필요

## 📝 라이선스

이 프로젝트는 내부 사용을 위한 것입니다.