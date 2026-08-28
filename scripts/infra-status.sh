#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/infra-common.sh"

verify_aws_identity

echo "Cuenta: ${AWS_ACCOUNT_ID}"
echo "Perfil: ${AWS_PROFILE}"
echo "Región: ${AWS_REGION}"

if stack_exists "${CORE_STACK_NAME}"; then
  instance_id="$(stack_output "${CORE_STACK_NAME}" "RelayInstanceId")"
  echo "Core: $(stack_status "${CORE_STACK_NAME}")"
  echo "EC2: ${instance_id} ($(instance_state "${instance_id}"))"
  echo "Elastic IP: $(stack_output "${CORE_STACK_NAME}" "RelayElasticIpAddress")"
else
  echo "Core: no desplegado"
fi

if stack_exists "${EDGE_STACK_NAME}"; then
  echo "Edge: $(stack_status "${EDGE_STACK_NAME}")"
  echo "Global Accelerator: $(stack_output "${EDGE_STACK_NAME}" "AcceleratorDnsName")"
else
  echo "Edge: eliminado (sin cobro fijo de Global Accelerator)"
fi

