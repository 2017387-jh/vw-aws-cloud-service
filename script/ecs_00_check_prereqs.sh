#!/usr/bin/env bash
set -euo pipefail
source .env

command -v aws >/dev/null || { echo "[ERROR] aws CLI not found"; exit 1; }
aws sts get-caller-identity >/dev/null || { echo "[ERROR] AWS credentials not configured"; exit 1; }

echo "[OK] AWS CLI and credentials ready."
echo "[INFO] Region: $AWS_REGION, Account: $ACCOUNT_ID"
