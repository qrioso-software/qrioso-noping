#!/usr/bin/env bash
set -euo pipefail

: "${SOURCE_URI:?}"
: "${EXPECTED_SHA256:?}"
: "${ELASTIC_IP:?}"
: "${DIRECT_ENDPOINT:?}"
: "${ACCELERATED_ENDPOINT:?}"
: "${DEPLOYMENT_REGION:?}"
: "${MAX_CLIENTS:?}"
: "${PROJECT_PREFIX:?}"
: "${STAGE:?}"
: "${AWS_REGION:?}"

if ! cloud-init status --wait; then
  echo "cloud-init terminó con error; verificando el bootstrap requerido antes de continuar." >&2
  command -v wg >/dev/null
  getent group "${PROJECT_PREFIX}" >/dev/null
  test -f "/etc/${PROJECT_PREFIX}-noping/access-keys.yaml"
  systemctl is-active --quiet nftables.service
fi

install_root="$(mktemp -d /var/tmp/ridenow-install.XXXXXX)"
trap 'rm -rf -- "${install_root}"' EXIT
aws s3 cp "${SOURCE_URI}" "${install_root}/release.tar.gz" --region "${DEPLOYMENT_REGION}" --only-show-errors
printf '%s  %s\n' "${EXPECTED_SHA256}" "${install_root}/release.tar.gz" | sha256sum -c -
tar -C "${install_root}" -xzf "${install_root}/release.tar.gz"
for binary in ridenow-token ridenow-accessd ridenow-relay; do
  test -x "${install_root}/${binary}"
done

install -o root -g root -m 0755 "${install_root}/ridenow-token" /usr/local/bin/ridenow-token
install -o root -g root -m 0755 "${install_root}/ridenow-accessd" /usr/local/bin/ridenow-accessd
install -o root -g root -m 0755 "${install_root}/ridenow-relay" /usr/local/bin/ridenow-relay
install -d -o root -g root -m 0755 /usr/local/libexec
install -o root -g root -m 0755 "${install_root}/ridenow-relay-network.sh" /usr/local/libexec/ridenow-relay-network.sh
install -o root -g root -m 0755 "${install_root}/ridenow-health-metric.sh" /usr/local/libexec/ridenow-health-metric.sh
install -o root -g root -m 0644 "${install_root}/ridenow-accessd.service" /etc/systemd/system/ridenow-accessd.service
install -o root -g root -m 0644 "${install_root}/ridenow-relay.service" /etc/systemd/system/ridenow-relay.service
install -o root -g root -m 0644 "${install_root}/ridenow-health-metric.service" /etc/systemd/system/ridenow-health-metric.service
install -o root -g root -m 0644 "${install_root}/ridenow-health-metric.timer" /etc/systemd/system/ridenow-health-metric.timer
install -d -o root -g "${PROJECT_PREFIX}" -m 02750 "/etc/${PROJECT_PREFIX}-noping"
install -d -o "${PROJECT_PREFIX}" -g "${PROJECT_PREFIX}" -m 0750 "/var/lib/${PROJECT_PREFIX}-noping/metrics"
install -d -o root -g root -m 0700 /etc/wireguard

if [[ ! -s /etc/wireguard/wg-direct.key ]]; then
  umask 077
  wg genkey >/etc/wireguard/wg-direct.key
fi
if [[ ! -s /etc/wireguard/wg-accelerated.key ]]; then
  umask 077
  wg genkey >/etc/wireguard/wg-accelerated.key
fi
wg_direct_private="$(< /etc/wireguard/wg-direct.key)"
wg_accelerated_private="$(< /etc/wireguard/wg-accelerated.key)"
printf '%s' "${wg_direct_private}" | wg pubkey >/etc/wireguard/wg-direct.pub
printf '%s' "${wg_accelerated_private}" | wg pubkey >/etc/wireguard/wg-accelerated.pub

cat >/etc/wireguard/wg-direct.conf <<WIREGUARD_DIRECT
[Interface]
Address = 10.78.0.1/24
ListenPort = 51820
PrivateKey = ${wg_direct_private}
SaveConfig = false
WIREGUARD_DIRECT
cat >/etc/wireguard/wg-accelerated.conf <<WIREGUARD_ACCELERATED
[Interface]
Address = 10.79.0.1/24
ListenPort = 51821
PrivateKey = ${wg_accelerated_private}
SaveConfig = false
WIREGUARD_ACCELERATED
chmod 0600 /etc/wireguard/wg-direct.key /etc/wireguard/wg-accelerated.key /etc/wireguard/wg-direct.conf /etc/wireguard/wg-accelerated.conf
chmod 0644 /etc/wireguard/wg-direct.pub /etc/wireguard/wg-accelerated.pub

if [[ ! -s "/etc/${PROJECT_PREFIX}-noping/tls.key" ]]; then
  umask 077
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "/etc/${PROJECT_PREFIX}-noping/tls.key"
fi
openssl pkey -in "/etc/${PROJECT_PREFIX}-noping/tls.key" -check -noout >/dev/null
certificate_temp="$(mktemp "/etc/${PROJECT_PREFIX}-noping/.tls.crt.XXXXXX")"
if ! openssl req -x509 -new -key "/etc/${PROJECT_PREFIX}-noping/tls.key" -sha256 -days 365 \
  -subj '/CN=Qrioso NoPing Relay' \
  -addext 'basicConstraints=critical,CA:FALSE' \
  -addext 'keyUsage=critical,digitalSignature,keyEncipherment' \
  -addext 'extendedKeyUsage=serverAuth' \
  -addext "subjectAltName=IP:${ELASTIC_IP}" \
  -out "${certificate_temp}"; then
  rm -f -- "${certificate_temp}"
  exit 1
fi
mv -f -- "${certificate_temp}" "/etc/${PROJECT_PREFIX}-noping/tls.crt"
chown "root:${PROJECT_PREFIX}" "/etc/${PROJECT_PREFIX}-noping/tls.crt" "/etc/${PROJECT_PREFIX}-noping/tls.key"
chmod 0640 "/etc/${PROJECT_PREFIX}-noping/tls.crt" "/etc/${PROJECT_PREFIX}-noping/tls.key"

cat >"/etc/${PROJECT_PREFIX}-noping/accessd.env" <<ENVIRONMENT
RIDENOW_TLS_CERT=/etc/${PROJECT_PREFIX}-noping/tls.crt
RIDENOW_TLS_KEY=/etc/${PROJECT_PREFIX}-noping/tls.key
RIDENOW_DIRECT_ENDPOINT=${DIRECT_ENDPOINT}
RIDENOW_ACCELERATED_ENDPOINT=${ACCELERATED_ENDPOINT}
RIDENOW_MAX_CLIENTS=${MAX_CLIENTS}
RIDENOW_WG_PUBLIC_KEY_A=$(< /etc/wireguard/wg-direct.pub)
RIDENOW_WG_PUBLIC_KEY_B=$(< /etc/wireguard/wg-accelerated.pub)
RIDENOW_WG_INTERFACE_A=wg-direct
RIDENOW_WG_INTERFACE_B=wg-accelerated
ENVIRONMENT
cat >"/etc/${PROJECT_PREFIX}-noping/metrics.env" <<ENVIRONMENT
RIDENOW_METRIC_NAMESPACE=${PROJECT_PREFIX}/NoPing
RIDENOW_STAGE=${STAGE}
RIDENOW_AWS_REGION=${AWS_REGION}
RIDENOW_TLS_CERT=/etc/${PROJECT_PREFIX}-noping/tls.crt
ENVIRONMENT
chown "root:${PROJECT_PREFIX}" "/etc/${PROJECT_PREFIX}-noping/accessd.env" "/etc/${PROJECT_PREFIX}-noping/metrics.env"
chmod 0640 "/etc/${PROJECT_PREFIX}-noping/accessd.env" "/etc/${PROJECT_PREFIX}-noping/metrics.env"
chown "root:${PROJECT_PREFIX}" "/etc/${PROJECT_PREFIX}-noping/access-keys.yaml"
chmod 0640 "/etc/${PROJECT_PREFIX}-noping/access-keys.yaml"

/usr/local/bin/ridenow-token validate --file "/etc/${PROJECT_PREFIX}-noping/access-keys.yaml"
systemctl daemon-reload
systemctl enable --now wg-quick@wg-direct.service wg-quick@wg-accelerated.service
systemctl is-active --quiet wg-quick@wg-direct.service
systemctl is-active --quiet wg-quick@wg-accelerated.service
systemctl enable --now ridenow-accessd.service
systemctl is-active --quiet ridenow-accessd.service
systemctl disable --now ridenow-health.service >/dev/null 2>&1 || systemctl stop ridenow-health.service >/dev/null 2>&1 || true
systemctl enable --now ridenow-relay.service
systemctl restart ridenow-accessd.service ridenow-relay.service
systemctl is-active --quiet ridenow-accessd.service
systemctl is-active --quiet ridenow-relay.service
systemctl enable --now ridenow-health-metric.timer
curl --fail --silent --show-error http://127.0.0.1:8081/healthz >/dev/null
curl --fail --silent --show-error http://127.0.0.1:8080/healthz >/dev/null
curl --fail --silent --show-error http://127.0.0.1:8082/healthz >/dev/null

spki_pin="$(openssl x509 -in "/etc/${PROJECT_PREFIX}-noping/tls.crt" -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256 -binary | base64 -w0)"
printf 'TLS_SPKI_PIN=sha256/%s\n' "${spki_pin}"
