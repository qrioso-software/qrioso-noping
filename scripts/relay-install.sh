#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/infra-common.sh"

if [[ "$#" -ne 3 ]]; then
  echo "Uso interno: relay-install.sh <instance-id> <elastic-ip> <accelerator-dns>" >&2
  exit 2
fi

instance_id="$1"
elastic_ip="$2"
accelerator_dns="$3"

if [[ ! "${instance_id}" =~ ^i-[0-9a-f]{8,17}$ ]]; then
  echo "Instance ID inválido: ${instance_id}" >&2
  exit 1
fi
if [[ ! "${elastic_ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "Elastic IP inválida: ${elastic_ip}" >&2
  exit 1
fi
if [[ ! "${accelerator_dns}" =~ ^[A-Za-z0-9.-]+\.awsglobalaccelerator\.com$ ]]; then
  echo "DNS de Global Accelerator inválido: ${accelerator_dns}" >&2
  exit 1
fi

verify_aws_identity
require_docker
require_stack_stable "${CORE_STACK_NAME}"
require_stack_stable "${EDGE_STACK_NAME}"

expected_instance_id="$(stack_output "${CORE_STACK_NAME}" "RelayInstanceId")"
expected_elastic_ip="$(stack_output "${CORE_STACK_NAME}" "RelayElasticIpAddress")"
expected_accelerator_dns="$(stack_output "${EDGE_STACK_NAME}" "AcceleratorDnsName")"
if [[ "${instance_id}" != "${expected_instance_id}" || "${elastic_ip}" != "${expected_elastic_ip}" || "${accelerator_dns}" != "${expected_accelerator_dns}" ]]; then
  echo "Los destinos solicitados no coinciden exactamente con los outputs actuales de los stacks ${CORE_STACK_NAME}/${EDGE_STACK_NAME}." >&2
  exit 1
fi

tagged_instance_id="$(aws ec2 describe-instances \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --instance-ids "${instance_id}" \
  --filters \
    "Name=tag:Project,Values=${PROJECT_PREFIX}-noping" \
    "Name=tag:Stage,Values=${STAGE}" \
  --query 'Reservations[].Instances[].InstanceId | [0]' \
  --output text)"
if [[ "${tagged_instance_id}" != "${instance_id}" ]]; then
  echo "La instancia ${instance_id} no pertenece al proyecto/entorno esperado (${PROJECT_PREFIX}-noping/${STAGE})." >&2
  exit 1
fi

"${SCRIPT_DIR}/relay-build.sh"

artifacts_bucket="$(stack_output "${CORE_STACK_NAME}" "RelayArtifactsBucketName")"
expected_bucket="${PROJECT_PREFIX}-noping-${STAGE}-artifacts-${AWS_ACCOUNT_ID}-${AWS_REGION}"
if [[ "${artifacts_bucket}" != "${expected_bucket}" ]]; then
  echo "Bucket de artefactos inesperado: ${artifacts_bucket}" >&2
  exit 1
fi

remote_script_path="${SCRIPT_DIR}/relay-remote-install.sh"
if [[ ! -r "${remote_script_path}" ]]; then
  echo "No se encontró el instalador remoto: ${remote_script_path}" >&2
  exit 1
fi

temporary_dir="$(mktemp -d)"
artifact_path="${temporary_dir}/ridenow-relay-linux-arm64.tar.gz"
parameters_path="${temporary_dir}/ssm-parameters.json"
s3_key=""
infra_env_temp=""

cleanup() {
  if [[ -n "${s3_key}" ]]; then
    aws s3 rm "s3://${artifacts_bucket}/${s3_key}" \
      --profile "${AWS_PROFILE}" \
      --region "${AWS_REGION}" \
      >/dev/null 2>&1 || true
  fi
  if [[ -n "${infra_env_temp}" && -f "${infra_env_temp}" ]]; then
    rm -f -- "${infra_env_temp}"
  fi
  rm -rf -- "${temporary_dir}"
}
trap cleanup EXIT

COPYFILE_DISABLE=1 tar --no-xattrs -C "${PROJECT_ROOT}/dist/relay-linux-arm64" -czf "${artifact_path}" \
  ridenow-token \
  ridenow-accessd \
  ridenow-relay \
  ridenow-accessd.service \
  ridenow-relay.service \
  ridenow-relay-network.sh \
  ridenow-health-metric.sh \
  ridenow-health-metric.service \
  ridenow-health-metric.timer

artifact_sha256="$(shasum -a 256 "${artifact_path}" | awk '{print $1}')"
s3_key="relay/${artifact_sha256}.tar.gz"
aws s3 cp "${artifact_path}" "s3://${artifacts_bucket}/${s3_key}" \
  --only-show-errors \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}"

for _ in {1..30}; do
  ping_status="$(aws ssm describe-instance-information \
    --profile "${AWS_PROFILE}" \
    --region "${AWS_REGION}" \
    --filters "Key=InstanceIds,Values=${instance_id}" \
    --query 'InstanceInformationList[0].PingStatus' \
    --output text)"
  if [[ "${ping_status}" == "Online" ]]; then
    break
  fi
  sleep 2
done
if [[ "${ping_status:-}" != "Online" ]]; then
  echo "La instancia ${instance_id} no aparece Online en Systems Manager." >&2
  exit 1
fi

remote_script=""
IFS= read -r -d '' remote_script < "${remote_script_path}" || true
printf -v remote_preamble \
  'SOURCE_URI=%q\nEXPECTED_SHA256=%q\nELASTIC_IP=%q\nDIRECT_ENDPOINT=%q\nACCELERATED_ENDPOINT=%q\nDEPLOYMENT_REGION=%q\nMAX_CLIENTS=%q\nPROJECT_PREFIX=%q\nSTAGE=%q\nAWS_REGION=%q\n' \
  "s3://${artifacts_bucket}/${s3_key}" \
  "${artifact_sha256}" \
  "${elastic_ip}" \
  "${elastic_ip}:51820" \
  "${accelerator_dns}:51821" \
  "${AWS_REGION}" \
  "${MAX_CLIENTS}" \
  "${PROJECT_PREFIX}" \
  "${STAGE}" \
  "${AWS_REGION}"
remote_command="${remote_preamble}${remote_script}"

jq -n --arg command "${remote_command}" '{commands: [$command]}' > "${parameters_path}"
command_id="$(aws ssm send-command \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --instance-ids "${instance_id}" \
  --document-name AWS-RunShellScript \
  --comment "Install Qrioso NoPing relay ${artifact_sha256}" \
  --parameters "file://${parameters_path}" \
  --query 'Command.CommandId' \
  --output text)"

if ! aws ssm wait command-executed \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --command-id "${command_id}" \
  --instance-id "${instance_id}"; then
  aws ssm get-command-invocation \
    --profile "${AWS_PROFILE}" \
    --region "${AWS_REGION}" \
    --command-id "${command_id}" \
    --instance-id "${instance_id}" \
    --query '{Status:Status,Output:StandardOutputContent,Error:StandardErrorContent}' \
    --output yaml >&2
  exit 1
fi

status="$(aws ssm get-command-invocation \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --command-id "${command_id}" \
  --instance-id "${instance_id}" \
  --query Status \
  --output text)"
if [[ "${status}" != "Success" ]]; then
  echo "La instalación remota terminó en estado ${status}." >&2
  exit 1
fi

remote_output="$(aws ssm get-command-invocation \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --command-id "${command_id}" \
  --instance-id "${instance_id}" \
  --query StandardOutputContent \
  --output text)"
tls_spki_line="$(printf '%s\n' "${remote_output}" | grep '^TLS_SPKI_PIN=sha256/' | tail -n 1 || true)"
tls_spki_pin="${tls_spki_line#TLS_SPKI_PIN=}"
if [[ ! "${tls_spki_pin}" =~ ^sha256/[A-Za-z0-9+/]{43}=$ ]]; then
  echo "La instalación terminó sin devolver el pin SPKI del certificado TLS." >&2
  exit 1
fi

infra_env_temp="$(mktemp "${PROJECT_ROOT}/.env.infra.tmp.XXXXXX")"
chmod 0600 "${infra_env_temp}"
existing_access_token=""
if [[ -f "${PROJECT_ROOT}/.env.infra" ]]; then
  existing_access_token="$(sed -n 's/^AccessToken=//p' "${PROJECT_ROOT}/.env.infra")"
  if [[ -n "${existing_access_token}" && ! "${existing_access_token}" =~ ^qnp_[a-z0-9][a-z0-9-]{2,31}_[A-Za-z0-9_-]{43}$ ]]; then
    echo "AccessToken existente en .env.infra no tiene el formato esperado; no se reemplazó el fichero." >&2
    exit 1
  fi
fi
printf '%s\n' \
  '# Configuración local compilada dentro del piloto de Windows; no subir a Git' \
  "AccessApiBaseUri=https://${elastic_ip}:8443" \
  "TlsSpkiPin=${tls_spki_pin}" \
  > "${infra_env_temp}"
if [[ -n "${existing_access_token}" ]]; then
  printf '%s\n' "AccessToken=${existing_access_token}" >> "${infra_env_temp}"
fi
mv -f -- "${infra_env_temp}" "${PROJECT_ROOT}/.env.infra"
infra_env_temp=""

printf '%s\n' "${tls_spki_line}"
echo "Servicios de control instalados en ${instance_id} por SSM y artefacto SHA-256 ${artifact_sha256}."
echo "Configuración local del piloto guardada en ${PROJECT_ROOT}/.env.infra; se preservó AccessToken si ya existía."
