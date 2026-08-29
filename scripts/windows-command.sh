#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
infra_environment_file="${PROJECT_ROOT}/.env.infra"

if [[ ! -r "${infra_environment_file}" || ! -f "${infra_environment_file}" ]]; then
  echo "No se encontró ${infra_environment_file}; ejecuta make infra-up primero." >&2
  exit 1
fi

entry_count="$(awk '
  /^[[:space:]]*($|#)/ { next }
  { count++ }
  END { print count + 0 }
' "${infra_environment_file}")"
access_api_count="$(awk -F= '$1 == "AccessApiBaseUri" { count++ } END { print count + 0 }' "${infra_environment_file}")"
tls_pin_count="$(awk -F= '$1 == "TlsSpkiPin" { count++ } END { print count + 0 }' "${infra_environment_file}")"

if [[ "${entry_count}" != "2" || "${access_api_count}" != "1" || "${tls_pin_count}" != "1" ]]; then
  echo ".env.infra debe contener exactamente AccessApiBaseUri y TlsSpkiPin, una vez cada uno." >&2
  exit 1
fi

access_api_base_uri="$(sed -n 's/\r$//; s/^AccessApiBaseUri=//p' "${infra_environment_file}")"
tls_spki_pin="$(sed -n 's/\r$//; s/^TlsSpkiPin=//p' "${infra_environment_file}")"
if [[ ! "${access_api_base_uri}" =~ ^https://[A-Za-z0-9.-]+:8443/?$ ]]; then
  echo "AccessApiBaseUri no tiene el formato HTTPS esperado en el puerto 8443." >&2
  exit 1
fi
if [[ ! "${tls_spki_pin}" =~ ^sha256/[A-Za-z0-9+/]{43}=$ ]]; then
  echo "TlsSpkiPin no tiene el formato SPKI SHA-256 esperado." >&2
  exit 1
fi

printf '%s\n' 'Set-ExecutionPolicy -Scope Process Bypass -Force; & ".\build-windows-pilot.ps1" -InfraEnvironmentFile ".\.env.infra"'
