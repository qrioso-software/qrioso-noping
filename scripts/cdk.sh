#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/infra-common.sh"
CDK_ARGUMENTS=("$@")

case "${1:-}" in
  --version)
    if [[ "$#" -ne 1 ]]; then
      echo "--version no acepta otros argumentos en este wrapper." >&2
      exit 2
    fi
    ;;
  synth|diff|deploy|destroy)
    ;;
  *)
    echo "Subcomando CDK no permitido. Usa make infra-synth/diff/up/down/update/destroy." >&2
    exit 2
    ;;
esac

validate_mutation_options() {
  local action="$1"
  local target_stack="$2"
  local option_index=0
  local option value
  local has_exclusively=false
  local has_force=false
  local has_approval=false
  local has_parameters=false
  local options=("${CDK_ARGUMENTS[@]:2}")

  while [[ "${option_index}" -lt "${#options[@]}" ]]; do
    option="${options[${option_index}]}"
    case "${action}:${option}" in
      deploy:--exclusively)
        [[ "${has_exclusively}" == "false" ]] || return 1
        has_exclusively=true
        option_index=$((option_index + 1))
        ;;
      deploy:--require-approval)
        [[ "${has_approval}" == "false" ]] || return 1
        [[ "$((option_index + 1))" -lt "${#options[@]}" ]] || return 1
        value="${options[$((option_index + 1))]}"
        [[ "${value}" == "never" ]] || return 1
        has_approval=true
        option_index=$((option_index + 2))
        ;;
      deploy:--parameters)
        [[ "${has_parameters}" == "false" && "${target_stack}" == "${EDGE_STACK_NAME}" ]] || return 1
        [[ "$((option_index + 1))" -lt "${#options[@]}" ]] || return 1
        value="${options[$((option_index + 1))]}"
        [[ "${value}" =~ ^${EDGE_STACK_NAME}:RelayInstanceId=i-[0-9a-f]{8,17}$ ]] || return 1
        has_parameters=true
        option_index=$((option_index + 2))
        ;;
      destroy:--exclusively)
        [[ "${has_exclusively}" == "false" ]] || return 1
        has_exclusively=true
        option_index=$((option_index + 1))
        ;;
      destroy:--force)
        [[ "${has_force}" == "false" ]] || return 1
        has_force=true
        option_index=$((option_index + 1))
        ;;
      *)
        return 1
        ;;
    esac
  done

  if [[ "${action}" == "deploy" ]]; then
    [[ "${has_exclusively}" == "true" && "${has_approval}" == "true" ]] || return 1
    if [[ "${target_stack}" == "${EDGE_STACK_NAME}" ]]; then
      [[ "${has_parameters}" == "true" ]] || return 1
    else
      [[ "${has_parameters}" == "false" ]] || return 1
    fi
  else
    [[ "${has_exclusively}" == "true" && "${has_force}" == "true" ]] || return 1
  fi
}

if ! docker info >/dev/null 2>&1; then
  echo "Docker Desktop no está iniciado." >&2
  exit 1
fi

IMAGE_NAME="${PROJECT_PREFIX}-noping-cdk:local"
mkdir -p "${PROJECT_ROOT}/infra/cdk.out"
case "${1:-}" in
  synth|diff|deploy)
  find "${PROJECT_ROOT}/infra/cdk.out" -mindepth 1 -delete
  ;;
esac

case "${1:-}" in
  deploy|destroy)
    action="$1"
    target_stack="${2:-}"
    if [[ "${target_stack}" != "${CORE_STACK_NAME}" && "${target_stack}" != "${EDGE_STACK_NAME}" ]]; then
      echo "El target CDK debe ser exactamente ${CORE_STACK_NAME} o ${EDGE_STACK_NAME}." >&2
      exit 1
    fi
    if [[ "${CONFIRM_CDK_ACTION:-}" != "${action}:${target_stack}" ]]; then
      echo "Mutación CDK bloqueada. Usa los targets make infra-up/down/update/destroy." >&2
      exit 1
    fi
    if ! validate_mutation_options "${action}" "${target_stack}"; then
      echo "Opciones CDK rechazadas: el wrapper solo permite el flujo exacto y revisado del proyecto." >&2
      exit 2
    fi
    verify_aws_identity
    ;;
esac

docker build --tag "${IMAGE_NAME}" "${PROJECT_ROOT}/infra"

cdk_budget_email="${BUDGET_EMAIL}"
if [[ "${1:-}" == "destroy" && -z "${cdk_budget_email}" ]]; then
  # CDK still evaluates the whole app during destroy. This non-routable value
  # exists only in the synthesized, unapplied core template so cost shutdown
  # cannot be blocked if the operator removed BUDGET_EMAIL after deployment.
  cdk_budget_email="destroy-only@example.invalid"
fi

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

DOCKER_ARGS+=(--env "BUDGET_EMAIL=${cdk_budget_email}")

run_cdk() {
  docker run "${DOCKER_ARGS[@]}" "${IMAGE_NAME}" "$@" --profile "${AWS_PROFILE}"
}

if [[ "${1:-}" == "deploy" ]]; then
  require_budget_email_value="${BUDGET_EMAIL}"
  if [[ -z "${require_budget_email_value}" ]]; then
    echo "BUDGET_EMAIL es obligatorio antes de deploy." >&2
    exit 1
  fi

  target_stack="${CDK_ARGUMENTS[1]}"
  run_cdk synth "${target_stack}" --exclusively
  run_cdk diff "${target_stack}" --exclusively --no-change-set
fi

run_cdk "${CDK_ARGUMENTS[@]}"
