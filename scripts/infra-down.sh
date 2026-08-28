#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/infra-common.sh"

verify_aws_identity
require_docker

core_present=false
if ! stack_exists "${CORE_STACK_NAME}"; then
  echo "El core ${CORE_STACK_NAME} no existe; no hay EC2 que apagar."
else
  core_present=true
  require_stack_stable "${CORE_STACK_NAME}"
  instance_id="$(stack_output "${CORE_STACK_NAME}" "RelayInstanceId")"
  state="$(instance_state "${instance_id}")"

  case "${state}" in
    running|pending)
      echo "Apagando EC2 ${instance_id}..."
      aws ec2 stop-instances \
        --profile "${AWS_PROFILE}" \
        --region "${AWS_REGION}" \
        --instance-ids "${instance_id}" \
        >/dev/null
      aws ec2 wait instance-stopped \
        --profile "${AWS_PROFILE}" \
        --region "${AWS_REGION}" \
        --instance-ids "${instance_id}"
      ;;
    stopping)
      echo "Esperando que EC2 ${instance_id} termine de apagarse..."
      aws ec2 wait instance-stopped \
        --profile "${AWS_PROFILE}" \
        --region "${AWS_REGION}" \
        --instance-ids "${instance_id}"
      ;;
    stopped)
      echo "EC2 ${instance_id} ya está apagada."
      ;;
    *)
      echo "Estado inesperado para EC2 ${instance_id}: ${state}." >&2
      exit 1
      ;;
  esac
fi

if stack_exists "${EDGE_STACK_NAME}"; then
  echo "Eliminando ${EDGE_STACK_NAME} para detener el cobro fijo de Global Accelerator..."
  "${SCRIPT_DIR}/cdk.sh" destroy "${EDGE_STACK_NAME}" --exclusively --force
else
  echo "El edge ${EDGE_STACK_NAME} ya está eliminado."
fi

echo "Infraestructura en modo ahorro."
if [[ "${core_present}" == "true" ]]; then
  echo "Persisten el EBS, la Elastic IP, la VPC, IAM, alarmas y budget; la EC2 no genera cargo de cómputo y Global Accelerator fue eliminado."
else
  echo "No existe ningún stack del proyecto; no quedó infraestructura que apagar."
fi
