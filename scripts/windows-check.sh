#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/load-env.sh"

docker run --rm \
  --volume "${PROJECT_ROOT}:/source:ro" \
  --mount "type=volume,source=${PROJECT_PREFIX}-noping-nuget,target=/root/.nuget/packages" \
  mcr.microsoft.com/dotnet/sdk:10.0 \
  bash -lc 'cp -R /source/apps/windows /tmp/windows && cd /tmp/windows && dotnet test tests/QriosoNoPing.Core.Tests/QriosoNoPing.Core.Tests.csproj -c Release'

