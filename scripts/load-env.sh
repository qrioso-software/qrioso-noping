#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "${PROJECT_ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${PROJECT_ROOT}/.env"
  set +a
fi

export PROJECT_PREFIX="${PROJECT_PREFIX:-ridenow}"
export STAGE="${STAGE:-dev}"
export AWS_PROFILE="${AWS_PROFILE:-ridenow-main}"
export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-009160027850}"
export INSTANCE_TYPE="${INSTANCE_TYPE:-t4g.small}"
export RELAY_AMI_ID="${RELAY_AMI_ID:-ami-068e33c5263812a9b}"
export MAX_CLIENTS="${MAX_CLIENTS:-10}"
export MONTHLY_BUDGET_USD="${MONTHLY_BUDGET_USD:-60}"
export BUDGET_EMAIL="${BUDGET_EMAIL:-}"
export CORE_STACK_NAME="${PROJECT_PREFIX}-noping-${STAGE}-core"
export EDGE_STACK_NAME="${PROJECT_PREFIX}-noping-${STAGE}-edge"

if [[ ! "${PROJECT_PREFIX}" =~ ^[a-z][a-z0-9-]{1,19}$ ]]; then
  echo "PROJECT_PREFIX debe usar minúsculas, números o guiones y tener 2-20 caracteres." >&2
  exit 1
fi

if [[ "${PROJECT_PREFIX}" != "ridenow" ]]; then
  echo "PROJECT_PREFIX debe ser ridenow para este entorno; recibido: ${PROJECT_PREFIX}." >&2
  exit 1
fi

if [[ "${AWS_PROFILE}" != "ridenow-main" ]]; then
  echo "AWS_PROFILE debe ser ridenow-main para este proyecto; recibido: ${AWS_PROFILE}." >&2
  exit 1
fi

if [[ "${AWS_REGION}" != "us-east-1" ]]; then
  echo "AWS_REGION debe ser us-east-1 para este MVP; recibido: ${AWS_REGION}." >&2
  exit 1
fi

if [[ "${AWS_ACCOUNT_ID}" != "009160027850" ]]; then
  echo "AWS_ACCOUNT_ID debe ser 009160027850 para este entorno; recibido: ${AWS_ACCOUNT_ID}." >&2
  exit 1
fi

if [[ ! "${RELAY_AMI_ID}" =~ ^ami-[0-9a-f]{8,17}$ ]]; then
  echo "RELAY_AMI_ID no tiene un formato de AMI válido." >&2
  exit 1
fi

if [[ ! "${MAX_CLIENTS}" =~ ^([1-9]|10)$ ]]; then
  echo "MAX_CLIENTS debe ser un entero entre 1 y 10 para el MVP inicial." >&2
  exit 1
fi

if [[ -n "${BUDGET_EMAIL}" && ! "${BUDGET_EMAIL}" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
  echo "BUDGET_EMAIL no tiene un formato de correo válido." >&2
  exit 1
fi
