#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/load-env.sh"

if ! docker info >/dev/null 2>&1; then
  echo "Docker Desktop no está iniciado." >&2
  exit 1
fi

IMAGE_NAME="${PROJECT_PREFIX}-noping-cdk:local"
mkdir -p "${PROJECT_ROOT}/infra/cdk.out"
if [[ "${1:-}" == "synth" ]]; then
  find "${PROJECT_ROOT}/infra/cdk.out" -mindepth 1 -maxdepth 1 -delete
fi

docker build --tag "${IMAGE_NAME}" "${PROJECT_ROOT}/infra"

DOCKER_ARGS=(
  --rm
  --volume "${PROJECT_ROOT}/infra/cdk.out:/app/cdk.out"
  --volume "${HOME}/.aws:/root/.aws:ro"
  --env "AWS_PROFILE=${AWS_PROFILE}"
  --env "AWS_REGION=${AWS_REGION}"
  --env "AWS_DEFAULT_REGION=${AWS_REGION}"
  --env "AWS_SDK_LOAD_CONFIG=1"
  --env "PROJECT_PREFIX=${PROJECT_PREFIX}"
  --env "STAGE=${STAGE}"
  --env "INSTANCE_TYPE=${INSTANCE_TYPE}"
  --env "RELAY_AMI_ID=${RELAY_AMI_ID}"
  --env "MAX_CLIENTS=${MAX_CLIENTS}"
  --env "MONTHLY_BUDGET_USD=${MONTHLY_BUDGET_USD}"
)

if [[ -n "${BUDGET_EMAIL:-}" ]]; then
  DOCKER_ARGS+=(--env "BUDGET_EMAIL=${BUDGET_EMAIL}")
fi

docker run "${DOCKER_ARGS[@]}" "${IMAGE_NAME}" "$@" --profile "${AWS_PROFILE}"
