#!/usr/bin/env bash
set -euo pipefail
source .env
aws configure set region "$AWS_REGION"

echo "[INFO] Create ECS cluster: $DDN_ECS_CLUSTER"
aws ecs create-cluster --cluster-name "$DDN_ECS_CLUSTER" >/dev/null || true

echo "[OK] ECS cluster ready."
