#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/load-env.sh"

docker run --rm \
  --volume "${PROJECT_ROOT}:/source:ro" \
  --mount "type=volume,source=${PROJECT_PREFIX}-noping-nuget,target=/root/.nuget/packages" \
  mcr.microsoft.com/dotnet/sdk:10.0 \
  bash -lc 'cp -R /source/apps/windows /tmp/windows && cd /tmp/windows && dotnet test tests/QriosoNoPing.Core.Tests/QriosoNoPing.Core.Tests.csproj -c Release && dotnet publish src/QriosoNoPing.Service/QriosoNoPing.Service.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true --output /tmp/qrioso-service-publish && test -s "/tmp/qrioso-service-publish/Qrioso NoPing Service.exe"'

docker run --rm \
  --volume "${PROJECT_ROOT}:/source:ro" \
  mcr.microsoft.com/powershell:7.5-alpine-3.20 \
  pwsh -NoLogo -NoProfile -Command \
  '& /source/apps/windows/packaging/test-infra-environment.ps1; & /source/apps/windows/packaging/test-integrity.ps1'
