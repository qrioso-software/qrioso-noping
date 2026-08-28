#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/load-env.sh"

verify_aws_identity() {
  local actual_account
  actual_account="$(aws sts get-caller-identity \
    --profile "${AWS_PROFILE}" \
    --query Account \
    --output text)"

  if [[ "${actual_account}" != "${AWS_ACCOUNT_ID}" ]]; then
    echo "Cuenta AWS incorrecta. Esperada=${AWS_ACCOUNT_ID}; actual=${actual_account}." >&2
    exit 1
  fi
}

require_docker() {
  if ! docker info >/dev/null 2>&1; then
    echo "Docker Desktop no está iniciado." >&2
    exit 1
  fi
}

stack_exists() {
  local stack_name="$1"
  aws cloudformation describe-stacks \
    --profile "${AWS_PROFILE}" \
    --region "${AWS_REGION}" \
    --stack-name "${stack_name}" \
    >/dev/null 2>&1
}

stack_status() {
  local stack_name="$1"
  aws cloudformation describe-stacks \
    --profile "${AWS_PROFILE}" \
    --region "${AWS_REGION}" \
    --stack-name "${stack_name}" \
    --query 'Stacks[0].StackStatus' \
    --output text
}

require_stack_stable() {
  local stack_name="$1"
  local status
  status="$(stack_status "${stack_name}")"
  case "${status}" in
    CREATE_COMPLETE|UPDATE_COMPLETE|UPDATE_ROLLBACK_COMPLETE|IMPORT_COMPLETE)
      ;;
    *)
      echo "El stack ${stack_name} no está estable: ${status}. Revisa CloudFormation antes de continuar." >&2
      exit 1
      ;;
  esac
}

stack_output() {
  local stack_name="$1"
  local output_key="$2"
  local value
  value="$(aws cloudformation describe-stacks \
    --profile "${AWS_PROFILE}" \
    --region "${AWS_REGION}" \
    --stack-name "${stack_name}" \
    --query "Stacks[0].Outputs[?OutputKey=='${output_key}'].OutputValue | [0]" \
    --output text)"

  if [[ -z "${value}" || "${value}" == "None" ]]; then
    echo "El stack ${stack_name} no contiene el output ${output_key}." >&2
    exit 1
  fi
  printf '%s\n' "${value}"
}

instance_state() {
  local instance_id="$1"
  aws ec2 describe-instances \
    --profile "${AWS_PROFILE}" \
    --region "${AWS_REGION}" \
    --instance-ids "${instance_id}" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text
}
