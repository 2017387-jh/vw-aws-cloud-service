# ECS (Elastic Container Service) 스크립트 가이드

## 개요
ECS(Elastic Container Service)는 AWS의 완전 관리형 컨테이너 오케스트레이션 서비스입니다. 이 프로젝트에서는 GPU 기반 EC2 인스턴스에서 Triton Inference Server와 Flask API 서버를 실행하기 위해 ECS를 사용합니다.

## 📁 관련 파일
```
script/
├── ecs_00_prereqs.sh           # ECS 사전 요구사항 설정
├── ecs_01_create_cluster.sh    # ECS 클러스터 생성
├── ecs_02_capacity_gpu_asg.sh  # GPU Auto Scaling Group 설정
├── ecs_03_alb_and_sg.sh        # ALB 및 보안 그룹 설정
├── ecs_04_register_taskdef.sh  # Task Definition 등록
├── ecs_05_create_service.sh    # ECS 서비스 생성
├── ecs_06_update_service.sh    # ECS 서비스 업데이트
├── ecs_07_autoscaling.sh       # 오토스케일링 설정
├── ecs_98_delete_task_defs.sh  # Task Definition 정리
└── ecs_99_cleanup.sh           # 전체 ECS 리소스 정리
```

## 🏗️ ecs_00_prereqs.sh

### 기능
- ECS 실행을 위한 IAM 역할 및 인스턴스 프로파일 생성
- 필수 패키지 설치 및 AWS CLI 검증

### 상세 분석

#### 1. 패키지 설치 및 AWS CLI 검증
```bash
sudo yum install -y -q gettext jq
command -v aws >/dev/null || { echo "[ERROR] aws CLI not found"; exit 1; }
aws sts get-caller-identity >/dev/null || { echo "[ERROR] AWS credentials not configured"; exit 1; }
```
- `gettext`: 환경변수 치환을 위한 `envsubst` 명령어 제공
- `jq`: JSON 처리 및 검증
- AWS CLI 존재성 및 자격증명 검증

#### 2. IAM 역할 생성
```bash
aws iam create-role \
  --role-name $DDN_ECS_ROLE_NAME \
  --assume-role-policy-document '{
    "Version": "2008-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": { "Service": "ec2.amazonaws.com" },
        "Action": "sts:AssumeRole"
      }
    ]
  }'
```
- **역할 이름**: `ecsInstanceRole` (환경변수에서 정의)
- **신뢰 관계**: EC2 서비스가 이 역할을 assume 할 수 있도록 설정
- **용도**: EC2 인스턴스가 ECS 에이전트를 실행할 수 있는 권한 부여

#### 3. 관리형 정책 연결
```bash
aws iam attach-role-policy \
  --role-name $DDN_ECS_ROLE_NAME \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role
```
- AWS 관리형 정책 연결
- ECS 클러스터 등록, 태스크 실행 등 필수 권한 포함

#### 4. 인스턴스 프로파일 생성
```bash
aws iam create-instance-profile --instance-profile-name $DDN_ECS_PROFILE_NAME
aws iam add-role-to-instance-profile \
  --instance-profile-name $DDN_ECS_PROFILE_NAME \
  --role-name $DDN_ECS_ROLE_NAME
```
- EC2 인스턴스에 IAM 역할을 연결하기 위한 인스턴스 프로파일 생성
- 역할을 프로파일에 추가

---

## 🎯 ecs_01_create_cluster.sh

### 기능
- 기본 ECS 클러스터 생성
- 멱등성 보장 (중복 생성 방지)

### 상세 분석
```bash
aws ecs create-cluster --cluster-name "$DDN_ECS_CLUSTER" >/dev/null || true
```
- 간단한 클러스터 생성
- `|| true`로 이미 존재하는 클러스터도 에러 없이 처리
- 실제 컴퓨팅 리소스는 다음 단계에서 추가

---

## 🚀 ecs_02_capacity_gpu_asg.sh

### 기능
- GPU 최적화 AMI 기반 Auto Scaling Group 생성
- ECS Capacity Provider 설정
- 보안 그룹 및 Launch Template 구성

### 상세 분석

#### 1. GPU 최적화 AMI 조회
```bash
AMI_ID=$(aws ssm get-parameters \
  --names /aws/service/ecs/optimized-ami/amazon-linux-2/gpu/recommended/image_id \
  --query 'Parameters[0].Value' --output text)
```
- AWS Systems Manager Parameter Store에서 최신 ECS GPU AMI ID 조회
- NVIDIA 드라이버 및 ECS 에이전트 사전 설치된 AMI

#### 2. 보안 그룹 생성
```bash
ECS_SG_ID=$(aws ec2 create-security-group \
  --vpc-id "$DDN_VPC_ID" \
  --group-name "$DDN_ECS_SG_NAME" \
  --description "ECS GPU instances SG" \
  --query 'GroupId' --output text 2>/dev/null || true)
```
- ECS 인스턴스용 보안 그룹 생성
- 외부 통신을 위한 아웃바운드 전체 허용

#### 3. Launch Template 생성
```bash
USERDATA=$(cat <<EOF
#!/bin/bash
echo ECS_CLUSTER=${DDN_ECS_CLUSTER} >> /etc/ecs/ecs.config
EOF
)

LT_ID=$(aws ec2 create-launch-template \
  --launch-template-name "$DDN_LAUNCH_TEMPLATE_NAME" \
  --launch-template-data "{
    \"ImageId\": \"$AMI_ID\",
    \"InstanceType\": \"$DDN_ECS_INSTANCE_TYPE\",
    \"IamInstanceProfile\": {\"Name\": \"ecsInstanceRole\"},
    \"SecurityGroupIds\": [\"$ECS_SG_ID\"],
    \"UserData\": \"$(echo -n "$USERDATA" | base64 -w0)\"
  }")
```
- **인스턴스 타입**: `g4dn.xlarge` (GPU 인스턴스)
- **IAM 프로파일**: 이전 단계에서 생성한 역할 연결
- **UserData**: ECS 클러스터 자동 등록 스크립트

#### 4. Auto Scaling Group 생성
```bash
aws autoscaling create-auto-scaling-group \
  --auto-scaling-group-name "$DDN_ASG_NAME" \
  --launch-template "LaunchTemplateId=$LT_ID,Version=\$Latest" \
  --min-size "$DDN_MIN_CAPACITY" \
  --desired-capacity "$DDN_DESIRED_CAPACITY" \
  --max-size "$DDN_MAX_CAPACITY" \
  --vpc-zone-identifier "$DDN_SUBNET_IDS"
```
- 다중 AZ 배포를 위한 서브넷 설정
- 용량 설정 (최소/원하는/최대)

#### 5. Capacity Provider 생성 및 연결
```bash
aws ecs create-capacity-provider \
  --name "$CP_NAME" \
  --auto-scaling-group-provider "autoScalingGroupArn=$ASG_ARN,managedScaling={status=ENABLED,targetCapacity=100,minimumScalingStepSize=1,maximumScalingStepSize=1},managedTerminationProtection=DISABLED"

aws ecs put-cluster-capacity-providers \
  --cluster "$DDN_ECS_CLUSTER" \
  --capacity-providers "${DDN_ASG_NAME}-cp" \
  --default-capacity-provider-strategy capacityProvider="${DDN_ASG_NAME}-cp",weight=1
```
- **Managed Scaling**: ECS가 ASG의 크기를 자동 조정
- **Target Capacity**: 100% (인스턴스 완전 활용)
- **클러스터 연결**: Capacity Provider를 기본 전략으로 설정

---

## 🔒 ecs_03_alb_and_sg.sh

### 기능
- Application Load Balancer 및 관련 보안 그룹 설정
- Target Group 생성 및 헬스체크 구성
- 네트워크 보안 설정

### 상세 분석

#### 1. ALB 보안 그룹 생성
```bash
ALB_SG_ID=$(aws ec2 create-security-group \
  --vpc-id "$DDN_VPC_ID" \
  --group-name "$DDN_ALB_SG_NAME" \
  --description "ALB SG")

aws ec2 authorize-security-group-ingress --group-id "$ALB_SG_ID" \
  --ip-permissions "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0}]"
```
- HTTP 포트 80 전체 공개
- 외부에서 ALB로의 접근 허용

#### 2. ECS 보안 그룹 규칙 추가
```bash
# Flask 포트만 ALB SG에서 허용
aws ec2 authorize-security-group-ingress --group-id "$ECS_SG_ID" \
  --ip-permissions "IpProtocol=tcp,FromPort=$DDN_FLASK_PORT,ToPort=$DDN_FLASK_PORT,UserIdGroupPairs=[{GroupId=$ALB_SG_ID}]"

# Triton 포트는 ECS SG 내부 통신만 허용
for P in "$DDN_TRITON_HTTP_PORT" "$DDN_TRITON_GRPC_PORT"; do
  aws ec2 authorize-security-group-ingress --group-id "$ECS_SG_ID" \
    --ip-permissions "IpProtocol=tcp,FromPort=$P,ToPort=$P,UserIdGroupPairs=[{GroupId=$ECS_SG_ID}]"
done
```
- **Flask 포트** (50101): ALB에서만 접근 가능
- **Triton 포트** (50201, 58202): 내부 통신만 허용 (보안 강화)

#### 3. ALB 생성
```bash
ALB_ARN=$(aws elbv2 create-load-balancer \
  --name "$DDN_ALB_NAME" \
  --type application \
  --security-groups "$ALB_SG_ID" \
  --subnets $SUBNET1 $SUBNET2)
```
- Application Load Balancer 생성
- 다중 AZ 배포

#### 4. Target Group 생성 (상세 헬스체크)
```bash
TG_FLASK_ARN=$(aws elbv2 create-target-group \
  --name "$DDN_TG_FLASK" \
  --protocol HTTP --port "$DDN_FLASK_PORT" \
  --vpc-id "$DDN_VPC_ID" \
  --target-type ip \
  --health-check-protocol HTTP \
  --health-check-path "$DDN_HEALTH_PATH" \
  --health-check-interval-seconds "$DDN_HEALTH_INTERVAL" \
  --health-check-timeout-seconds "$DDN_HEALTH_TIMEOUT" \
  --healthy-threshold-count "$DDN_HEALTH_HEALTHY" \
  --unhealthy-threshold-count "$DDN_HEALTH_UNHEALTHY")
```
- **Target Type**: `ip` (awsvpc 네트워크 모드용)
- **헬스체크 경로**: `/healthz`
- **간격/타임아웃**: 세밀한 헬스체크 설정

#### 5. 리스너 생성
```bash
LISTENER_ARN=$(aws elbv2 create-listener \
  --load-balancer-arn "$ALB_ARN" \
  --protocol HTTP --port 80 \
  --default-actions "Type=forward,TargetGroupArn=$TG_FLASK_ARN")
```
- HTTP 80 포트로 들어오는 모든 요청을 Flask Target Group으로 전달

#### 6. .env 파일 업데이트
```bash
if grep -q '^DDN_ALB_DNS=' .env; then
  sed -i "s|^DDN_ALB_DNS=.*|DDN_ALB_DNS=$ALB_DNS|" .env
else
  echo "DDN_ALB_DNS=$ALB_DNS" >> .env
fi
```
- ALB DNS 이름을 `.env` 파일에 자동 업데이트
- 후속 스크립트에서 사용

---

## 📋 ecs_04_register_taskdef.sh

### 기능
- Task Definition 템플릿에서 실제 Task Definition 생성
- CloudWatch 로그 그룹 생성
- JSON 검증 및 등록

### 상세 분석

#### 1. 환경 변수 자동 내보내기
```bash
set -a   # 자동으로 모든 변수 export
source .env
set +a
```
- `set -a`: 이후 할당되는 모든 변수를 자동으로 export
- `envsubst`에서 모든 환경변수에 접근 가능하도록 설정

#### 2. 패키지 설치 및 로그 그룹 생성
```bash
sudo yum install -y -q gettext jq
aws logs create-log-group --log-group-name "/ecs/$DDN_ECS_TASK_FAMILY"
```
- `gettext`: `envsubst` 명령어 제공
- CloudWatch 로그 그룹 사전 생성

#### 3. 템플릿 처리
```bash
envsubst < taskdef.json.tpl > taskdef.json
```
- 템플릿 파일의 환경변수 플레이스홀더를 실제 값으로 치환
- 예: `${DDN_ECS_TASK_FAMILY}` → `ddn-triton-task`

#### 4. JSON 검증
```bash
if ! jq empty taskdef.json >/dev/null 2>&1; then
  echo "[ERROR] taskdef.json is not valid JSON"
  exit 1
fi
```
- 생성된 JSON의 문법 검증
- 잘못된 환경변수로 인한 JSON 오류 사전 차단

#### 5. Task Definition 등록
```bash
REV=$(aws ecs register-task-definition \
  --cli-input-json file://taskdef.json \
  --query 'taskDefinition.revision' --output text)
```
- 생성된 JSON 파일을 ECS에 등록
- 리비전 번호 반환 (버전 관리)

---

## 🎯 ecs_05_create_service.sh

### 기능
- ECS 서비스 생성 및 ALB 연결
- 네트워크 구성 및 로드 밸런서 설정

### 상세 분석

#### 1. 리소스 정보 수집
```bash
ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names "$DDN_ALB_NAME" \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text)

TG_FLASK_ARN=$(aws elbv2 describe-target-groups \
  --names "$DDN_TG_FLASK" \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text)
```
- 이전 단계에서 생성한 리소스들의 ARN 수집

#### 2. 최신 Task Definition 조회
```bash
REV=$(aws ecs list-task-definitions \
  --family-prefix "$DDN_ECS_TASK_FAMILY" \
  --sort DESC --query 'taskDefinitionArns[0]' --output text)
```
- 가장 최신 리비전의 Task Definition 선택

#### 3. ECS 서비스 생성
```bash
aws ecs create-service \
  --cluster "$DDN_ECS_CLUSTER" \
  --service-name "$DDN_ECS_SERVICE" \
  --task-definition "$REV" \
  --desired-count "$DDN_ECS_DESIRED_COUNT" \
  --launch-type EC2 \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS_JSON],securityGroups=[\"$ECS_SG_ID\"],assignPublicIp=DISABLED}" \
  --load-balancers "targetGroupArn=$TG_FLASK_ARN,containerName=$DDN_ECS_CONTAINER,containerPort=$DDN_FLASK_PORT" \
  --health-check-grace-period-seconds 60
```
- **네트워크 모드**: `awsvpc` (각 태스크가 독립된 ENI 보유)
- **공인 IP**: 비활성화 (프라이빗 서브넷 사용)
- **로드 밸런서**: Flask 컨테이너만 ALB에 연결
- **헬스체크 유예기간**: 60초 (컨테이너 초기화 시간 고려)

---

## 🔄 ecs_06_update_service.sh

### 기능
- 기존 ECS 서비스를 최신 Task Definition으로 업데이트
- 롤링 업데이트 수행

---

## 📈 ecs_07_autoscaling.sh

### 기능
- ECS 서비스 및 ASG 오토스케일링 설정
- 메트릭 기반 자동 확장/축소

---

## 🗑️ ecs_99_cleanup.sh

### 기능
- 전체 ECS 인프라 완전 삭제
- 안전한 순서로 리소스 정리

### 상세 분석

#### 1. 서비스 중지 및 삭제
```bash
aws ecs update-service \
  --cluster "$DDN_ECS_CLUSTER" \
  --service "$DDN_ECS_SERVICE" \
  --desired-count 0

aws ecs delete-service \
  --cluster "$DDN_ECS_CLUSTER" \
  --service "$DDN_ECS_SERVICE" \
  --force
```
- 실행 중인 태스크를 0개로 설정
- 강제 서비스 삭제

#### 2. Auto Scaling Group 삭제
```bash
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name "$DDN_ASG_NAME" \
  --min-size 0 --desired-capacity 0

aws autoscaling delete-auto-scaling-group \
  --auto-scaling-group-name "$DDN_ASG_NAME" \
  --force-delete
```
- 인스턴스 수를 0으로 줄인 후 ASG 삭제
- 강제 삭제로 인스턴스 종료 대기 없이 진행

#### 3. ALB 및 관련 리소스 삭제
```bash
# 리스너 삭제
LISTENERS=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
  --query 'Listeners[].ListenerArn' --output text)
for L in $LISTENERS; do aws elbv2 delete-listener --listener-arn "$L"; done

# ALB 삭제
aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN"

# Target Group 삭제
aws elbv2 delete-target-group --target-group-arn "$TG_ARN"
```
- 의존성 순서에 따른 안전한 삭제

#### 4. Capacity Provider 정리
```bash
aws ecs put-cluster-capacity-providers \
  --cluster "$DDN_ECS_CLUSTER" \
  --capacity-providers [] \
  --default-capacity-provider-strategy []

aws ecs delete-capacity-provider --capacity-provider "${DDN_ASG_NAME}-cp"
```
- 클러스터에서 Capacity Provider 분리
- Capacity Provider 삭제

#### 5. 인스턴스 종료 대기
```bash
INSTANCE_IDS=$(aws ec2 describe-instances \
  --filters "Name=tag:aws:autoscaling:groupName,Values=$DDN_ASG_NAME" \
  --query 'Reservations[].Instances[].InstanceId' --output text)

if [ -n "$INSTANCE_IDS" ]; then
  aws ec2 wait instance-terminated --instance-ids $INSTANCE_IDS
fi
```
- ASG 소속 모든 인스턴스 ID 수집
- 완전 종료까지 대기

---

## 🚀 사용 시나리오

### 1. 전체 ECS 인프라 구축
```bash
# 순서대로 실행 필요
./ecs_00_prereqs.sh           # IAM 역할 준비
./ecs_01_create_cluster.sh    # 클러스터 생성
./ecs_02_capacity_gpu_asg.sh  # GPU ASG 설정
./ecs_03_alb_and_sg.sh        # ALB 및 보안 설정
./ecs_04_register_taskdef.sh  # Task Definition 등록
./ecs_05_create_service.sh    # 서비스 시작
```

### 2. 애플리케이션 업데이트
```bash
# 새 이미지를 ECR에 푸시한 후
./ecs_04_register_taskdef.sh  # 새 Task Definition 등록
./ecs_06_update_service.sh    # 롤링 업데이트
```

### 3. 오토스케일링 설정
```bash
./ecs_07_autoscaling.sh       # CPU/Memory 기반 확장
```

### 4. 완전한 정리
```bash
./ecs_99_cleanup.sh           # 모든 리소스 삭제
```

## ⚠️ 주의사항

### 1. 순서 의존성
- 스크립트들은 특정 순서로 실행되어야 함
- 각 단계의 성공 여부 확인 필요

### 2. GPU 인스턴스 비용
- g4dn.xlarge 인스턴스는 높은 비용 발생
- 불필요 시 즉시 정리 권장

### 3. 네트워크 설정
- VPC, 서브넷, 보안 그룹 사전 설정 필요
- 프라이빗 서브넷 사용으로 NAT Gateway 필요

### 4. 권한 관리
- ECS, EC2, IAM, ALB에 대한 광범위한 권한 필요
- 최소 권한 원칙 적용 권장

## 🔍 트러블슈팅

### 1. 태스크 시작 실패
```bash
# Task Definition 검증
aws ecs describe-task-definition --task-definition ddn-triton-task

# 클러스터 인스턴스 상태 확인
aws ecs list-container-instances --cluster ddn-ecs-cluster
```

### 2. ALB 헬스체크 실패
```bash
# Target Group 상태 확인
aws elbv2 describe-target-health --target-group-arn <TG_ARN>

# 보안 그룹 규칙 확인
aws ec2 describe-security-groups --group-ids <SG_ID>
```

### 3. 오토스케일링 문제
```bash
# ASG 활동 확인
aws autoscaling describe-scaling-activities --auto-scaling-group-name <ASG_NAME>

# Capacity Provider 상태
aws ecs describe-capacity-providers --capacity-providers <CP_NAME>
```

## 📊 모니터링

### 1. CloudWatch 메트릭
- ECS 서비스: CPU, Memory 사용률
- ALB: 요청 수, 응답 시간, 에러율
- EC2: 인스턴스 상태, GPU 사용률

### 2. 로그 확인
```bash
# ECS 태스크 로그
aws logs tail /ecs/ddn-triton-task --follow

# ALB 액세스 로그 (S3 버킷 설정 시)
```

### 3. 비용 최적화
- 스팟 인스턴스 활용 고려
- 예약 인스턴스로 비용 절감
- 사용하지 않는 리소스 정기 정리