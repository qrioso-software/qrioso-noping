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

temporary_dir="$(mktemp -d)"
artifact_path="${temporary_dir}/ridenow-relay-linux-arm64.tar.gz"
parameters_path="${temporary_dir}/ssm-parameters.json"
s3_key=""

cleanup() {
  if [[ -n "${s3_key}" ]]; then
    aws s3 rm "s3://${artifacts_bucket}/${s3_key}" \
      --profile "${AWS_PROFILE}" \
      --region "${AWS_REGION}" \
      >/dev/null 2>&1 || true
  fi
  rm -rf -- "${temporary_dir}"
}
trap cleanup EXIT

tar -C "${PROJECT_ROOT}/dist/relay-linux-arm64" -czf "${artifact_path}" \
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

printf -v source_uri '%q' "s3://${artifacts_bucket}/${s3_key}"
printf -v expected_sha '%q' "${artifact_sha256}"
printf -v direct_endpoint '%q' "${elastic_ip}:51820"
printf -v accelerated_endpoint '%q' "${accelerator_dns}:51821"
printf -v deployment_region '%q' "${AWS_REGION}"
# shellcheck disable=SC2153 # exported by load-env.sh through infra-common.sh
printf -v max_clients '%q' "${MAX_CLIENTS}"

remote_command="$(cat <<EOF
set -euo pipefail
cloud-init status --wait
install_root=\"\$(mktemp -d /var/tmp/ridenow-install.XXXXXX)\"
trap 'rm -rf -- \"\${install_root}\"' EXIT
aws s3 cp ${source_uri} \"\${install_root}/release.tar.gz\" --region ${deployment_region} --only-show-errors
printf '%s  %s\\n' ${expected_sha} \"\${install_root}/release.tar.gz\" | sha256sum -c -
tar -C \"\${install_root}\" -xzf \"\${install_root}/release.tar.gz\"
for binary in ridenow-token ridenow-accessd ridenow-relay; do test -x \"\${install_root}/\${binary}\"; done
install -o root -g root -m 0755 \"\${install_root}/ridenow-token\" /usr/local/bin/ridenow-token
install -o root -g root -m 0755 \"\${install_root}/ridenow-accessd\" /usr/local/bin/ridenow-accessd
install -o root -g root -m 0755 \"\${install_root}/ridenow-relay\" /usr/local/bin/ridenow-relay
install -d -o root -g root -m 0755 /usr/local/libexec
install -o root -g root -m 0755 \"\${install_root}/ridenow-relay-network.sh\" /usr/local/libexec/ridenow-relay-network.sh
install -o root -g root -m 0755 \"\${install_root}/ridenow-health-metric.sh\" /usr/local/libexec/ridenow-health-metric.sh
install -o root -g root -m 0644 \"\${install_root}/ridenow-accessd.service\" /etc/systemd/system/ridenow-accessd.service
install -o root -g root -m 0644 \"\${install_root}/ridenow-relay.service\" /etc/systemd/system/ridenow-relay.service
install -o root -g root -m 0644 \"\${install_root}/ridenow-health-metric.service\" /etc/systemd/system/ridenow-health-metric.service
install -o root -g root -m 0644 \"\${install_root}/ridenow-health-metric.timer\" /etc/systemd/system/ridenow-health-metric.timer
install -d -o root -g ${PROJECT_PREFIX} -m 02750 /etc/${PROJECT_PREFIX}-noping
install -d -o ${PROJECT_PREFIX} -g ${PROJECT_PREFIX} -m 0750 /var/lib/${PROJECT_PREFIX}-noping/metrics
install -d -o root -g root -m 0700 /etc/wireguard
if [[ ! -s /etc/wireguard/wg-direct.key ]]; then
  umask 077
  wg genkey >/etc/wireguard/wg-direct.key
fi
if [[ ! -s /etc/wireguard/wg-accelerated.key ]]; then
  umask 077
  wg genkey >/etc/wireguard/wg-accelerated.key
fi
wg_direct_private=\"\$(< /etc/wireguard/wg-direct.key)\"
wg_accelerated_private=\"\$(< /etc/wireguard/wg-accelerated.key)\"
printf '%s' \"\${wg_direct_private}\" | wg pubkey >/etc/wireguard/wg-direct.pub
printf '%s' \"\${wg_accelerated_private}\" | wg pubkey >/etc/wireguard/wg-accelerated.pub
cat >/etc/wireguard/wg-direct.conf <<WIREGUARD_DIRECT
[Interface]
Address = 10.78.0.1/24
ListenPort = 51820
PrivateKey = \${wg_direct_private}
SaveConfig = false
WIREGUARD_DIRECT
cat >/etc/wireguard/wg-accelerated.conf <<WIREGUARD_ACCELERATED
[Interface]
Address = 10.79.0.1/24
ListenPort = 51821
PrivateKey = \${wg_accelerated_private}
SaveConfig = false
WIREGUARD_ACCELERATED
chmod 0600 /etc/wireguard/wg-direct.key /etc/wireguard/wg-accelerated.key /etc/wireguard/wg-direct.conf /etc/wireguard/wg-accelerated.conf
chmod 0644 /etc/wireguard/wg-direct.pub /etc/wireguard/wg-accelerated.pub
if [[ ! -s /etc/${PROJECT_PREFIX}-noping/tls.key ]]; then
  umask 077
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out /etc/${PROJECT_PREFIX}-noping/tls.key
fi
openssl pkey -in /etc/${PROJECT_PREFIX}-noping/tls.key -check -noout >/dev/null
certificate_temp=\"\$(mktemp /etc/${PROJECT_PREFIX}-noping/.tls.crt.XXXXXX)\"
if ! openssl req -x509 -new -key /etc/${PROJECT_PREFIX}-noping/tls.key -sha256 -days 365 \\
  -subj '/CN=Qrioso NoPing Relay' \\
  -addext 'basicConstraints=critical,CA:FALSE' \\
  -addext 'keyUsage=critical,digitalSignature,keyEncipherment' \\
  -addext 'extendedKeyUsage=serverAuth' \\
  -addext 'subjectAltName=IP:${elastic_ip}' \\
  -out \"\${certificate_temp}\"; then
  rm -f -- \"\${certificate_temp}\"
  exit 1
fi
mv -f -- \"\${certificate_temp}\" /etc/${PROJECT_PREFIX}-noping/tls.crt
chown root:${PROJECT_PREFIX} /etc/${PROJECT_PREFIX}-noping/tls.crt /etc/${PROJECT_PREFIX}-noping/tls.key
chmod 0640 /etc/${PROJECT_PREFIX}-noping/tls.crt /etc/${PROJECT_PREFIX}-noping/tls.key
cat >/etc/${PROJECT_PREFIX}-noping/accessd.env <<ENVIRONMENT
RIDENOW_TLS_CERT=/etc/${PROJECT_PREFIX}-noping/tls.crt
RIDENOW_TLS_KEY=/etc/${PROJECT_PREFIX}-noping/tls.key
RIDENOW_DIRECT_ENDPOINT=${direct_endpoint}
RIDENOW_ACCELERATED_ENDPOINT=${accelerated_endpoint}
RIDENOW_MAX_CLIENTS=${max_clients}
RIDENOW_WG_PUBLIC_KEY_A=\$(< /etc/wireguard/wg-direct.pub)
RIDENOW_WG_PUBLIC_KEY_B=\$(< /etc/wireguard/wg-accelerated.pub)
RIDENOW_WG_INTERFACE_A=wg-direct
RIDENOW_WG_INTERFACE_B=wg-accelerated
ENVIRONMENT
cat >/etc/${PROJECT_PREFIX}-noping/metrics.env <<ENVIRONMENT
RIDENOW_METRIC_NAMESPACE=${PROJECT_PREFIX}/NoPing
RIDENOW_STAGE=${STAGE}
RIDENOW_AWS_REGION=${AWS_REGION}
RIDENOW_TLS_CERT=/etc/${PROJECT_PREFIX}-noping/tls.crt
ENVIRONMENT
chown root:${PROJECT_PREFIX} /etc/${PROJECT_PREFIX}-noping/accessd.env
chown root:${PROJECT_PREFIX} /etc/${PROJECT_PREFIX}-noping/metrics.env
chmod 0640 /etc/${PROJECT_PREFIX}-noping/accessd.env /etc/${PROJECT_PREFIX}-noping/metrics.env
chown root:${PROJECT_PREFIX} /etc/${PROJECT_PREFIX}-noping/access-keys.yaml
chmod 0640 /etc/${PROJECT_PREFIX}-noping/access-keys.yaml
/usr/local/bin/ridenow-token validate --file /etc/${PROJECT_PREFIX}-noping/access-keys.yaml
systemctl daemon-reload
systemctl enable --now wg-quick@wg-direct.service wg-quick@wg-accelerated.service
systemctl is-active --quiet wg-quick@wg-direct.service
systemctl is-active --quiet wg-quick@wg-accelerated.service
systemctl enable --now ridenow-accessd.service
systemctl is-active --quiet ridenow-accessd.service
systemctl disable --now ridenow-health.service
systemctl enable --now ridenow-relay.service
systemctl restart ridenow-accessd.service ridenow-relay.service
systemctl is-active --quiet ridenow-accessd.service
systemctl is-active --quiet ridenow-relay.service
systemctl enable --now ridenow-health-metric.timer
curl --fail --silent --show-error http://127.0.0.1:8081/healthz >/dev/null
curl --fail --silent --show-error http://127.0.0.1:8080/healthz >/dev/null
curl --fail --silent --show-error http://127.0.0.1:8082/healthz >/dev/null
spki_pin="\$(openssl x509 -in /etc/${PROJECT_PREFIX}-noping/tls.crt -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256 -binary | base64 -w0)"
printf 'TLS_SPKI_PIN=sha256/%s\n' "\${spki_pin}"
EOF
)"

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
if [[ "${remote_output}" == *"TLS_SPKI_PIN=sha256/"* ]]; then
  printf '%s\n' "${remote_output}" | grep 'TLS_SPKI_PIN=sha256/' | tail -n 1
else
  echo "La instalación terminó sin devolver el pin SPKI del certificado TLS." >&2
  exit 1
fi

echo "Servicios de control instalados en ${instance_id} por SSM y artefacto SHA-256 ${artifact_sha256}."
