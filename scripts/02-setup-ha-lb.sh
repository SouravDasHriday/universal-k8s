#!/bin/bash
# ==============================================================================
# scripts/02-setup-ha-lb.sh
# Optional High Availability (HA) Load Balancer & Virtual IP Setup
# Uses HAProxy + Keepalived on control-plane nodes for Bare-Metal & VMs.
# (Note: For AWS/Azure, you can also use native AWS NLB or Azure LB).
# ==============================================================================

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "[ERROR] Please run with sudo or as root: sudo $0"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -f "$PARENT_DIR/cluster.env" ]; then
  # shellcheck source=/dev/null
  source "$PARENT_DIR/cluster.env"
fi

VIP="${LOAD_BALANCER_VIP:-}"
MASTERS_LIST="${1:-}" # Optional comma-separated list of master IPs: e.g. "10.10.1.10,10.10.1.11,10.10.1.12"

echo "=========================================================="
echo " Setting up High Availability Load Balancer (HAProxy + Keepalived)"
echo " Virtual IP (VIP) : ${VIP:-Not specified (using external LB)}"
echo "=========================================================="

if [ -z "$VIP" ] && [ -z "$MASTERS_LIST" ]; then
  echo "[INFO] No VIP or Master list specified."
  echo "       If using AWS Network Load Balancer (NLB) or Azure Load Balancer,"
  echo "       you do NOT need this script. Point CONTROL_PLANE_ENDPOINT to your Cloud LB DNS."
  exit 0
fi

# Detect package manager
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y haproxy keepalived
elif command -v yum >/dev/null 2>&1; then
  yum install -y haproxy keepalived
fi

# Configure HAProxy to load-balance port 6443 across master nodes
PRIMARY_NIC="$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}' || ip -o -4 route show to default | awk '{print $5}')"

cat <<EOF > /etc/haproxy/haproxy.cfg
global
    log /dev/log local0
    log /dev/log local1 notice
    daemon

defaults
    log     global
    mode    tcp
    option  tcplog
    option  dontlognull
    timeout connect 5000ms
    timeout client  50000ms
    timeout server  50000ms

frontend k8s-api
    bind 0.0.0.0:6443
    mode tcp
    option tcplog
    default_backend k8s-api-backend

backend k8s-api-backend
    mode tcp
    option tcp-check
    balance roundrobin
EOF

# Append master backends
INDEX=1
IFS=',' read -ra ADDR <<< "$MASTERS_LIST"
for ip in "${ADDR[@]}"; do
  echo "    server master$INDEX $ip:6443 check fall 3 rise 2" >> /etc/haproxy/haproxy.cfg
  INDEX=$((INDEX + 1))
done

systemctl restart haproxy
systemctl enable haproxy

echo "SUCCESS: HAProxy configured and active on port 6443!"
