#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/infra-common.sh"

expected_confirmation="${PROJECT_PREFIX}-noping-${STAGE}"
if [[ "${CONFIRM_DESTROY:-}" != "${expected_confirmation}" ]]; then
  echo "Esta operación elimina EC2, EBS, llaves, EIP, Global Accelerator y toda la red." >&2
  echo "Ejecuta: CONFIRM_DESTROY=${expected_confirmation} make infra-destroy" >&2
  exit 1
fi

verify_aws_identity
require_docker

if stack_exists "${EDGE_STACK_NAME}"; then
  CONFIRM_CDK_ACTION="destroy:${EDGE_STACK_NAME}" \
    "${SCRIPT_DIR}/cdk.sh" destroy "${EDGE_STACK_NAME}" --exclusively --force
fi
if stack_exists "${CORE_STACK_NAME}"; then
  artifacts_bucket="$(stack_output "${CORE_STACK_NAME}" "RelayArtifactsBucketName")"
  expected_bucket_prefix="${PROJECT_PREFIX}-noping-${STAGE}-artifacts-${AWS_ACCOUNT_ID}-${AWS_REGION}"
  if [[ "${artifacts_bucket}" != "${expected_bucket_prefix}" ]]; then
    echo "Bucket de artefactos inesperado; se cancela el borrado: ${artifacts_bucket}" >&2
    exit 1
  fi
  aws s3 rm "s3://${artifacts_bucket}" \
    --recursive \
    --profile "${AWS_PROFILE}" \
    --region "${AWS_REGION}"
  aws cloudformation update-termination-protection \
    --no-enable-termination-protection \
    --stack-name "${CORE_STACK_NAME}" \
    --profile "${AWS_PROFILE}" \
    --region "${AWS_REGION}" \
    >/dev/null
  CONFIRM_CDK_ACTION="destroy:${CORE_STACK_NAME}" \
    "${SCRIPT_DIR}/cdk.sh" destroy "${CORE_STACK_NAME}" --exclusively --force
fi

echo "Infraestructura completa eliminada. Esta operación no conserva las llaves guardadas en la EC2."
