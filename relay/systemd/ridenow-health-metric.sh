#!/usr/bin/env bash
set -euo pipefail

namespace="${RIDENOW_METRIC_NAMESPACE:-ridenow/NoPing}"
stage="${RIDENOW_STAGE:-dev}"
region="${RIDENOW_AWS_REGION:-us-east-1}"
tls_certificate="${RIDENOW_TLS_CERT:-/etc/ridenow-noping/tls.crt}"
state_directory="/var/lib/ridenow-noping/metrics"
state_file="${state_directory}/ena-counters"
healthy=0

if curl --fail --silent --show-error --max-time 2 http://127.0.0.1:8080/healthz >/dev/null &&
  curl --fail --silent --show-error --max-time 2 http://127.0.0.1:8081/healthz >/dev/null &&
  curl --fail --silent --show-error --max-time 2 http://127.0.0.1:8082/healthz >/dev/null &&
  openssl x509 -in "${tls_certificate}" -checkend 2592000 -noout >/dev/null 2>&1 &&
  nft list chain inet ridenow_noping_filter input | grep --fixed-strings 'iifname { "wg-direct", "wg-accelerated" } drop' >/dev/null &&
  nft list chain inet ridenow_noping_filter forward | grep --fixed-strings 'iifname { "wg-direct", "wg-accelerated" } drop' >/dev/null; then
  healthy=1
fi

interface_name="$(ip -4 route show default | awk 'NR == 1 {print $5}')"
if [[ ! "${interface_name}" =~ ^[A-Za-z0-9_.-]{1,15}$ ]]; then
  healthy=0
fi

declare -A previous=()
if [[ -f "${state_file}" ]]; then
  while IFS='=' read -r key value; do
    if [[ "${key}" =~ ^[a-z_]+$ && "${value}" =~ ^[0-9]+$ ]]; then
      previous["${key}"]="${value}"
    fi
  done <"${state_file}"
fi

counter_names=(bw_in_allowance_exceeded bw_out_allowance_exceeded pps_allowance_exceeded conntrack_allowance_exceeded linklocal_allowance_exceeded)
declare -A cloudwatch_names=(
  [bw_in_allowance_exceeded]=BwInAllowanceExceeded
  [bw_out_allowance_exceeded]=BwOutAllowanceExceeded
  [pps_allowance_exceeded]=PpsAllowanceExceeded
  [conntrack_allowance_exceeded]=ConntrackAllowanceExceeded
  [linklocal_allowance_exceeded]=LinklocalAllowanceExceeded
)
metrics=("MetricName=ServiceHealthy,Dimensions=[{Name=Stage,Value=${stage}}],Value=${healthy},Unit=Count")
ena_total=0
state_temporary="$(mktemp "${state_directory}/.ena-counters.XXXXXX")"
trap 'rm -f -- "${state_temporary}"' EXIT

for counter_name in "${counter_names[@]}"; do
  current="$(ethtool -S "${interface_name}" 2>/dev/null | awk -F: -v name="${counter_name}" '$1 ~ "^[[:space:]]*" name "$" {gsub(/[[:space:]]/, "", $2); print $2; exit}')" || current=""
  if [[ ! "${current}" =~ ^[0-9]+$ ]]; then
    healthy=0
    current="${previous[${counter_name}]:-0}"
  fi
  prior="${previous[${counter_name}]:-${current}}"
  if (( current >= prior )); then
    delta=$((current - prior))
  else
    delta=0
  fi
  ena_total=$((ena_total + delta))
  printf '%s=%s\n' "${counter_name}" "${current}" >>"${state_temporary}"
  metrics+=("MetricName=${cloudwatch_names[${counter_name}]},Dimensions=[{Name=Stage,Value=${stage}}],Value=${delta},Unit=Count")
done
mv -f -- "${state_temporary}" "${state_file}"
trap - EXIT

metrics[0]="MetricName=ServiceHealthy,Dimensions=[{Name=Stage,Value=${stage}}],Value=${healthy},Unit=Count"
metrics+=("MetricName=EnaAllowanceExceeded,Dimensions=[{Name=Stage,Value=${stage}}],Value=${ena_total},Unit=Count")
aws cloudwatch put-metric-data --namespace "${namespace}" --metric-data "${metrics[@]}" --region "${region}"
