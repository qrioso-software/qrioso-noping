#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/load-env.sh"

OUTPUT_DIR="${PROJECT_ROOT}/dist/relay-linux-arm64"
mkdir -p "${OUTPUT_DIR}"

docker buildx build \
  --platform linux/arm64 \
  --target export \
  --output "type=local,dest=${OUTPUT_DIR}" \
  "${PROJECT_ROOT}/relay"

cp "${PROJECT_ROOT}"/relay/systemd/*.service "${OUTPUT_DIR}/"
cp "${PROJECT_ROOT}/relay/config/access-keys.example.yaml" "${OUTPUT_DIR}/"

echo "Binarios ARM64: ${OUTPUT_DIR}"
