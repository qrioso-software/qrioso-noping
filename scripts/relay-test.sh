#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/load-env.sh"

docker build --target test --tag "${PROJECT_PREFIX}-noping-relay-test:local" "${PROJECT_ROOT}/relay"

