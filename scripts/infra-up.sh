#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/infra-common.sh"

verify_aws_identity
require_docker

if stack_exists "${CORE_STACK_NAME}"; then
  echo "Core ${CORE_STACK_NAME} existente; no se actualiza durante el encendido diario."
else
  echo "Creando el core ${CORE_STACK_NAME} por primera vez..."
  "${SCRIPT_DIR}/cdk.sh" deploy "${CORE_STACK_NAME}" --exclusively --require-approval never
fi

require_stack_stable "${CORE_STACK_NAME}"

instance_id="$(stack_output "${CORE_STACK_NAME}" "RelayInstanceId")"
state="$(instance_state "${instance_id}")"

case "${state}" in
  stopped)
    echo "Encendiendo EC2 ${instance_id}..."
    aws ec2 start-instances \
      --profile "${AWS_PROFILE}" \
      --region "${AWS_REGION}" \
      --instance-ids "${instance_id}" \
      >/dev/null
    ;;
  stopping)
    echo "Esperando que EC2 ${instance_id} termine de apagarse..."
    aws ec2 wait instance-stopped \
      --profile "${AWS_PROFILE}" \
      --region "${AWS_REGION}" \
      --instance-ids "${instance_id}"
    aws ec2 start-instances \
      --profile "${AWS_PROFILE}" \
      --region "${AWS_REGION}" \
      --instance-ids "${instance_id}" \
      >/dev/null
    ;;
  pending|running)
    echo "EC2 ${instance_id} ya está ${state}."
    ;;
  *)
    echo "No se puede iniciar EC2 ${instance_id} desde el estado ${state}." >&2
    exit 1
    ;;
esac

echo "Esperando que EC2 y sus comprobaciones estén listas..."
aws ec2 wait instance-running \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --instance-ids "${instance_id}"
aws ec2 wait instance-status-ok \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --instance-ids "${instance_id}"

echo "Creando/actualizando el edge ${EDGE_STACK_NAME}..."
"${SCRIPT_DIR}/cdk.sh" deploy "${EDGE_STACK_NAME}" \
  --exclusively \
  --require-approval never \
  --parameters "${EDGE_STACK_NAME}:RelayInstanceId=${instance_id}"

elastic_ip="$(stack_output "${CORE_STACK_NAME}" "RelayElasticIpAddress")"
accelerator_dns="$(stack_output "${EDGE_STACK_NAME}" "AcceleratorDnsName")"

echo "Infraestructura encendida."
echo "Ruta A: ${elastic_ip}:51820"
echo "Ruta B: ${accelerator_dns}:51821"
