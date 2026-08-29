#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/load-env.sh"

windows_command="$(${SCRIPT_DIR}/windows-command.sh)"
grep -Fqx -- "$windows_command" "${PROJECT_ROOT}/README.md"
grep -Fqx -- "$windows_command" "${PROJECT_ROOT}/apps/windows/native/README.md"

docker run --rm \
  --volume "${PROJECT_ROOT}:/source:ro" \
  --mount "type=volume,source=${PROJECT_PREFIX}-noping-nuget,target=/root/.nuget/packages" \
  mcr.microsoft.com/dotnet/sdk:10.0 \
  bash -lc 'set -euo pipefail; cp -R /source/apps/windows /tmp/windows; access_uri="$(sed -n "s/^AccessApiBaseUri=//p" /source/.env.infra)"; tls_pin="$(sed -n "s/^TlsSpkiPin=//p" /source/.env.infra)"; access_token="$(sed -n "s/^AccessToken=//p" /source/.env.infra)"; [[ "$access_uri" =~ ^https://[A-Za-z0-9.-]+:8443$ ]]; [[ "$tls_pin" =~ ^sha256/[A-Za-z0-9+/]{43}=$ ]]; [[ "$access_token" =~ ^qnp_[a-z0-9][a-z0-9-]{2,31}_[A-Za-z0-9_-]{43}$ ]]; embedded_source=/tmp/windows/src/QriosoNoPing.Service/obj/QriosoNoPing.EmbeddedConfiguration.g.cs; mkdir -p "$(dirname "$embedded_source")"; printf "using System.Reflection;\n[assembly: AssemblyMetadata(\"QriosoNoPing.AccessApiBaseUri\", \"%s\")]\n[assembly: AssemblyMetadata(\"QriosoNoPing.TlsSpkiPin\", \"%s\")]\n[assembly: AssemblyMetadata(\"QriosoNoPing.AccessToken\", \"%s\")]\n" "$access_uri" "$tls_pin" "$access_token" > "$embedded_source"; cd /tmp/windows; dotnet test tests/QriosoNoPing.Core.Tests/QriosoNoPing.Core.Tests.csproj -c Release; dotnet publish src/QriosoNoPing.Service/QriosoNoPing.Service.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true --output /tmp/qrioso-service-publish; service_executable="/tmp/qrioso-service-publish/Qrioso NoPing Service.exe"; test -s "$service_executable"; for embedded_value in "$access_uri" "$tls_pin" "$access_token"; do grep -aF "$embedded_value" "$service_executable" >/dev/null; done'

docker run --rm \
  --volume "${PROJECT_ROOT}:/source:ro" \
  mcr.microsoft.com/powershell:7.5-alpine-3.20 \
  pwsh -NoLogo -NoProfile -Command \
  '& /source/apps/windows/packaging/test-embedded-configuration.ps1; & /source/apps/windows/packaging/test-integrity.ps1'
