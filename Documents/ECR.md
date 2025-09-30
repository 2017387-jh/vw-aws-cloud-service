# ECR (Elastic Container Registry) 스크립트 가이드

## 개요
ECR(Elastic Container Registry)은 AWS의 완전 관리형 Docker 컨테이너 레지스트리 서비스입니다. 이 문서는 Deep Denoising Triton 서버 Docker 이미지를 ECR에 저장하고 관리하는 스크립트들의 상세한 설명을 제공합니다.

## 📁 관련 파일
```
script/
├── ecr_create_repository.sh     # ECR 리포지토리 생성
├── ecr_delete_repository.sh     # ECR 리포지토리 삭제
├── ecr_load_docker_image.sh     # Docker 이미지 로드
├── ecr_push_docker_image.sh     # Docker 이미지 푸시
├── ecr_load_docker_image.bat    # Windows용 이미지 로드
└── ecr_push_docker_image.bat    # Windows용 이미지 푸시
```

## 🏗️ ecr_create_repository.sh

### 기능
- ECR 리포지토리 생성
- 중복 생성 방지
- 리포지토리 URI 출력

### 상세 분석

#### 1. 환경 설정
```bash
#!/usr/bin/env bash
set -euo pipefail
source .env
aws configure set region "$AWS_REGION"
```
- `set -euo pipefail`: 엄격한 오류 처리
  - `-e`: 명령어 실패 시 즉시 종료
  - `-u`: 정의되지 않은 변수 사용 시 오류
  - `-o pipefail`: 파이프라인 중 하나라도 실패하면 전체 실패
- AWS CLI 리전 설정

#### 2. 리포지토리 생성
```bash
aws ecr create-repository --repository-name "$DDN_ECR_REPO" || true
```
- `|| true`: 이미 존재하는 리포지토리여도 오류 무시
- 멱등성(idempotent) 보장 - 여러 번 실행해도 안전

#### 3. 리포지토리 URI 조회
```bash
aws ecr describe-repositories --repository-names "$DDN_ECR_REPO" \
  --query "repositories[0].repositoryUri" --output text
```
- JMESPath 쿼리로 URI만 추출
- 후속 스크립트에서 사용할 수 있도록 출력

### 환경 변수
- `DDN_ECR_REPO`: 생성할 ECR 리포지토리 이름 (예: `deepdenoising-triton`)
- `AWS_REGION`: AWS 리전 (예: `ap-northeast-2`)

---

## 🗑️ ecr_delete_repository.sh

### 기능
- ECR 리포지토리 완전 삭제
- 모든 이미지 삭제 후 리포지토리 삭제
- 안전한 정리 작업

### 상세 분석

#### 1. 이미지 목록 조회
```bash
IMAGE_IDS=$(aws ecr list-images \
  --repository-name "$DDN_ECR_REPO" \
  --query 'imageIds[*]' \
  --output json)
```
- 리포지토리 내 모든 이미지 ID 조회
- JSON 형태로 출력하여 삭제 명령에 사용

#### 2. 배치 이미지 삭제
```bash
if [ "$IMAGE_IDS" != "[]" ]; then
  aws ecr batch-delete-image \
    --repository-name "$DDN_ECR_REPO" \
    --image-ids "$IMAGE_IDS" || true
else
  echo "[INFO] No images found in repo"
fi
```
- 이미지가 있을 경우에만 삭제 실행
- `batch-delete-image`: 여러 이미지를 한 번에 삭제
- `|| true`: 삭제 실패해도 계속 진행

#### 3. 리포지토리 삭제
```bash
aws ecr delete-repository --repository-name "$DDN_ECR_REPO" --force || true
```
- `--force`: 이미지가 남아있어도 강제 삭제
- 완전한 정리 보장

---

## 📥 ecr_load_docker_image.sh

### 기능
- TAR 파일로부터 Docker 이미지 로드
- 로컬 Docker 환경에 이미지 추가
- ECR 푸시 전 준비 단계

### 상세 분석

#### 1. TAR 파일 존재 확인
```bash
if [ ! -f "$DDN_ECR_IMG_TAR" ]; then
  echo "[ERROR] TAR file not found: $DDN_ECR_IMG_TAR"
  exit 1
fi
```
- 파일 존재성 검증
- 사전 에러 방지

#### 2. Docker 이미지 로드
```bash
docker load -i "$DDN_ECR_IMG_TAR"
```
- TAR 파일로부터 이미지 복원
- 로컬 Docker 데몬에 이미지 등록

### 사용 시나리오
이 스크립트는 다음과 같은 상황에서 사용됩니다:
1. 다른 머신에서 생성한 이미지를 TAR로 전달받은 경우
2. CI/CD 파이프라인에서 빌드된 이미지를 배포하는 경우
3. 오프라인 환경에서 이미지를 전달하는 경우

### 환경 변수
- `DDN_ECR_IMG_TAR`: Docker 이미지 TAR 파일 경로 (예: `deepdenoising.triton.tar`)

---

## 📤 ecr_push_docker_image.sh

### 기능
- Docker 이미지를 ECR에 푸시
- 자동 태깅 및 로그인 처리
- 성능 측정 포함

### 상세 분석

#### 1. 성능 측정 시작
```bash
START_TIME=$(date +%s)
```
- UNIX 타임스탬프로 시작 시간 기록
- 푸시 소요 시간 측정용

#### 2. ECR 로그인
```bash
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
```
- ECR 임시 토큰 발급
- Docker 클라이언트에 자동 로그인
- 파이프를 통한 안전한 패스워드 전달

#### 3. 이미지 URI 구성
```bash
IMAGE_URI_BASE="$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$DDN_ECR_REPO"
IMAGE_URI_TAG="$IMAGE_URI_BASE:$DDN_ECR_TAG"
IMAGE_URI_LATEST="$IMAGE_URI_BASE:latest"
```
- ECR 표준 URI 형식 구성
- 태그된 버전과 latest 버전 모두 준비

#### 4. 소스 이미지 감지
```bash
if docker image inspect "$DDN_LOCAL_IMG:$DDN_ECR_TAG" >/dev/null 2>&1; then
  SRC_REF="$DDN_LOCAL_IMG:$DDN_ECR_TAG"
else
  # 최신 이미지 사용
  SRC_REF=$(docker images -q | head -n1)
  if [ -z "$SRC_REF" ]; then
    echo "[ERROR] No image found after docker load"
    exit 1
  fi
fi
```
- 지정된 이미지명이 있으면 사용
- 없으면 가장 최근 이미지 자동 선택
- 이미지 부재 시 명확한 오류 메시지

#### 5. 이미지 태깅
```bash
docker tag "$SRC_REF" "$IMAGE_URI_TAG"
docker tag "$SRC_REF" "$IMAGE_URI_LATEST"
```
- ECR URI 형식으로 태그 생성
- 버전 태그와 latest 태그 동시 생성

#### 6. ECR 푸시
```bash
docker push "$IMAGE_URI_TAG"
docker push "$IMAGE_URI_LATEST"
```
- 태그된 버전과 latest 버전 모두 푸시
- ECR에서 이미지 레이어 중복 제거 자동 처리

#### 7. 성능 리포트
```bash
END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))
echo "[TIME] Total elapsed time: ${ELAPSED} seconds"
```
- 전체 푸시 소요 시간 계산 및 출력
- 네트워크 성능 모니터링용

### 환경 변수
- `AWS_REGION`: AWS 리전
- `ACCOUNT_ID`: AWS 계정 ID
- `DDN_ECR_REPO`: ECR 리포지토리 이름
- `DDN_ECR_TAG`: 이미지 태그 (예: `1.0`)
- `DDN_LOCAL_IMG`: 로컬 이미지 이름

---

## 🚀 사용 시나리오

### 1. 최초 ECR 설정
```bash
# 1. ECR 리포지토리 생성
./ecr_create_repository.sh

# 2. Docker 이미지 로드 (TAR 파일이 있는 경우)
./ecr_load_docker_image.sh

# 3. ECR에 이미지 푸시
./ecr_push_docker_image.sh
```

### 2. 이미지 업데이트
```bash
# 새로운 이미지 로드
./ecr_load_docker_image.sh

# ECR에 푸시 (자동으로 기존 버전 덮어씀)
./ecr_push_docker_image.sh
```

### 3. 완전한 정리
```bash
# 모든 이미지와 리포지토리 삭제
./ecr_delete_repository.sh
```

### 4. Windows 환경
```cmd
REM Windows 사용자의 경우 .bat 파일 사용
ecr_load_docker_image.bat
ecr_push_docker_image.bat
```

## 🔧 이미지 관리 전략

### 태깅 전략
- **Semantic Versioning**: `1.0`, `1.1`, `2.0` 등
- **Latest Tag**: 항상 최신 버전을 가리킴
- **날짜 태그**: `2024-01-15` 형식도 고려 가능

### 이미지 최적화
```bash
# 이미지 크기 확인
docker images | grep deepdenoising-triton

# 불필요한 레이어 제거 (multi-stage build 권장)
# Dockerfile에서 최적화 필요
```

### 보안 고려사항
- ECR 이미지 스캐닝 활성화 권장
- 정기적인 베이스 이미지 업데이트
- 취약점 패치 적용

## ⚠️ 주의사항

1. **네트워크**: 대용량 이미지 푸시 시 네트워크 대역폭 고려
2. **권한**: ECR 리포지토리에 대한 적절한 IAM 권한 필요
3. **스토리지**: ECR 스토리지 비용 모니터링
4. **리전**: 이미지와 ECS 클러스터가 동일한 리전에 있어야 함
5. **버전 관리**: 이미지 태그 정책 수립 필요

## 🔍 트러블슈팅

### ECR 로그인 실패
```bash
# AWS 자격 증명 확인
aws sts get-caller-identity

# ECR 권한 확인
aws ecr describe-repositories
```

### 이미지 푸시 실패
```bash
# 리포지토리 존재 여부 확인
aws ecr describe-repositories --repository-names deepdenoising-triton

# 디스크 공간 확인
df -h
docker system df
```

### 성능 최적화
```bash
# Docker 빌드 캐시 최적화
docker system prune -a

# 병렬 레이어 푸시 설정
export DOCKER_BUILDKIT=1
```

## 📊 모니터링

### ECR 사용량 확인
```bash
# 리포지토리 크기 확인
aws ecr describe-repositories --query 'repositories[*].[repositoryName,repositorySizeInBytes]'

# 이미지 목록
aws ecr list-images --repository-name deepdenoising-triton
```

### 비용 최적화
- 오래된 이미지 자동 정리 정책 설정
- 이미지 스캐닝 결과 모니터링
- 리포지토리별 사용량 추적