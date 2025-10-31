#!/usr/bin/env bash
set -euo pipefail

# ===================================================================
# ECS 전체 파이프라인 자동 실행 스크립트
# ecs_00 ~ ecs_07 순서대로 실행
# ===================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 색상 정의 (선택적)
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 로깅 함수
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "\n${YELLOW}========================================${NC}"
    echo -e "${YELLOW}  STEP $1${NC}"
    echo -e "${YELLOW}========================================${NC}\n"
}

# 에러 핸들러
error_handler() {
    log_error "Script failed at step: $CURRENT_STEP"
    exit 1
}
trap error_handler ERR

# .env 로드 확인
if [ ! -f ".env" ]; then
    log_error ".env file not found in $SCRIPT_DIR"
    exit 1
fi

source .env
log_info "Loaded .env configuration"
log_info "Region: $AWS_REGION, Cluster: $DDN_ECS_CLUSTER"

# ===================================================================
# STEP 0: Prerequisites (IAM Roles, S3 VPC Endpoint)
# ===================================================================
CURRENT_STEP="0: Prerequisites"
log_step "$CURRENT_STEP"
if [ -f "ecs_00_prereqs.sh" ]; then
    bash ecs_00_prereqs.sh
    log_success "Step 0 completed: IAM Roles & VPC Endpoint ready"
else
    log_error "ecs_00_prereqs.sh not found"
    exit 1
fi

# ===================================================================
# STEP 1: Create ECS Cluster
# ===================================================================
CURRENT_STEP="1: Create ECS Cluster"
log_step "$CURRENT_STEP"
if [ -f "ecs_01_create_cluster.sh" ]; then
    bash ecs_01_create_cluster.sh
    log_success "Step 1 completed: ECS Cluster created"
else
    log_error "ecs_01_create_cluster.sh not found"
    exit 1
fi

# ===================================================================
# STEP 2: Create Auto Scaling Group with GPU instances
# ===================================================================
CURRENT_STEP="2: Create ASG with GPU Instances"
log_step "$CURRENT_STEP"
if [ -f "ecs_02_capacity_gpu_asg.sh" ]; then
    bash ecs_02_capacity_gpu_asg.sh
    log_success "Step 2 completed: Auto Scaling Group created"
else
    log_error "ecs_02_capacity_gpu_asg.sh not found"
    exit 1
fi

# ===================================================================
# STEP 3: Create ALB and Security Groups
# ===================================================================
CURRENT_STEP="3: Create ALB and Security Groups"
log_step "$CURRENT_STEP"
if [ -f "ecs_03_alb_and_sg.sh" ]; then
    bash ecs_03_alb_and_sg.sh
    log_success "Step 3 completed: ALB & Security Groups ready"
else
    log_error "ecs_03_alb_and_sg.sh not found"
    exit 1
fi

# ===================================================================
# STEP 4: Register Task Definition
# ===================================================================
CURRENT_STEP="4: Register Task Definition"
log_step "$CURRENT_STEP"
if [ -f "ecs_04_register_taskdef.sh" ]; then
    bash ecs_04_register_taskdef.sh
    log_success "Step 4 completed: Task Definition registered"
else
    log_error "ecs_04_register_taskdef.sh not found"
    exit 1
fi

# ===================================================================
# STEP 5: Create ECS Service
# ===================================================================
CURRENT_STEP="5: Create ECS Service"
log_step "$CURRENT_STEP"
if [ -f "ecs_05_create_service.sh" ]; then
    bash ecs_05_create_service.sh
    log_success "Step 5 completed: ECS Service created"
else
    log_error "ecs_05_create_service.sh not found"
    exit 1
fi

# ===================================================================
# STEP 6: Wait for Service to be Stable (Optional)
# ===================================================================
CURRENT_STEP="6: Wait for Service Stability"
log_step "$CURRENT_STEP"
log_info "Waiting for ECS service to reach stable state..."
log_info "This may take 2-5 minutes (EC2 provisioning + Docker pull + Health checks)"

aws ecs wait services-stable \
    --cluster "$DDN_ECS_CLUSTER" \
    --services "$DDN_ECS_SERVICE" \
    --region "$AWS_REGION" \
    && log_success "ECS Service is now STABLE" \
    || log_error "Service failed to stabilize (check AWS Console for details)"

# ===================================================================
# STEP 7: Configure Auto Scaling Policies
# ===================================================================
CURRENT_STEP="7: Configure Auto Scaling"
log_step "$CURRENT_STEP"
if [ -f "ecs_07_autoscaling.sh" ]; then
    bash ecs_07_autoscaling.sh
    log_success "Step 7 completed: Auto Scaling policies applied"
else
    log_error "ecs_07_autoscaling.sh not found"
    exit 1
fi

# ===================================================================
# Final Summary
# ===================================================================
echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}  ALL STEPS COMPLETED SUCCESSFULLY!${NC}"
echo -e "${GREEN}========================================${NC}\n"

# ALB DNS 출력
ALB_DNS=$(aws elbv2 describe-load-balancers \
    --names "$DDN_ALB_NAME" \
    --query 'LoadBalancers[0].DNSName' \
    --output text \
    --region "$AWS_REGION" 2>/dev/null || echo "N/A")

log_info "Deployment Summary:"
echo "  - ECS Cluster    : $DDN_ECS_CLUSTER"
echo "  - ECS Service    : $DDN_ECS_SERVICE"
echo "  - ALB Endpoint   : http://$ALB_DNS"
echo "  - Health Check   : http://$ALB_DNS$DDN_HEALTH_PATH"
echo "  - Min Capacity   : $DDN_MIN_CAPACITY"
echo "  - Max Capacity   : $DDN_MAX_CAPACITY"
echo ""

log_info "Testing the deployment:"
echo "  curl http://$ALB_DNS$DDN_HEALTH_PATH"
echo ""

log_info "Monitor service status:"
echo "  aws ecs describe-services --cluster $DDN_ECS_CLUSTER --services $DDN_ECS_SERVICE --query 'services[0].[serviceName,status,runningCount,desiredCount]' --output table"
echo ""

log_success "ECS deployment pipeline completed! 🚀"
