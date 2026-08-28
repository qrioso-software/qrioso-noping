#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/infra-common.sh"

if [[ "${CONFIRM_UPDATE:-}" != "${CORE_STACK_NAME}" ]]; then
  echo "Actualizar core puede reemplazar recursos y requiere revisar make infra-diff." >&2
  echo "Ejecuta: CONFIRM_UPDATE=${CORE_STACK_NAME} make infra-update" >&2
  exit 1
fi

verify_aws_identity
require_docker
"${SCRIPT_DIR}/cdk.sh" deploy "${CORE_STACK_NAME}" --exclusively --require-approval never
"${SCRIPT_DIR}/infra-up.sh"
