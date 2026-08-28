#!/usr/bin/env bash
set -euo pipefail

action="${1:-}"
tun_name="${RIDENOW_TUN_NAME:-ridenow0}"
virtual_network="10.80.0.0/24"
virtual_gateway="10.80.0.1/24"

remove_tables() {
  nft delete table inet ridenow_noping_filter >/dev/null 2>&1 || true
  nft delete table ip ridenow_noping_nat >/dev/null 2>&1 || true
}

case "${action}" in
  up)
    if ! ip link show dev "${tun_name}" >/dev/null 2>&1; then
      ip tuntap add dev "${tun_name}" mode tun
    fi
    ip address replace "${virtual_gateway}" dev "${tun_name}"
    ip link set dev "${tun_name}" mtu 1356 up
    remove_tables
    nft -f - <<NFT
table inet ridenow_noping_filter {
  chain input {
    type filter hook input priority filter; policy accept;
    iifname "wg-direct" ip daddr 10.78.0.1 udp dport 51900 accept
    iifname "wg-accelerated" ip daddr 10.79.0.1 udp dport 51900 accept
    iifname { "wg-direct", "wg-accelerated" } drop
  }
  chain forward {
    type filter hook forward priority filter; policy accept;
    iifname "${tun_name}" ip saddr ${virtual_network} ct state new,established,related accept
    oifname "${tun_name}" ip daddr ${virtual_network} ct state established,related accept
    iifname "${tun_name}" drop
    oifname "${tun_name}" drop
    iifname { "wg-direct", "wg-accelerated" } drop
    oifname { "wg-direct", "wg-accelerated" } drop
  }
}
table ip ridenow_noping_nat {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr ${virtual_network} oifname != "${tun_name}" masquerade
  }
}
NFT
    ;;
  down)
    remove_tables
    if ip link show dev "${tun_name}" >/dev/null 2>&1; then
      ip link delete dev "${tun_name}"
    fi
    ;;
  *)
    echo "Uso: ridenow-relay-network.sh up|down" >&2
    exit 2
    ;;
esac
