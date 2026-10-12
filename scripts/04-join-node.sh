#!/bin/bash
# ==============================================================================
# scripts/04-join-node.sh
# Universal Node Joiner (Supports Worker and Control-Plane Nodes)
# Automatically runs prerequisite prep if not already done.
# ==============================================================================

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "[ERROR] Please run with sudo or as root: sudo $0"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ROLE="${1:-worker}" # "worker" or "control-plane"
CUSTOM_JOIN_CMD="${2:-}"

echo "=========================================================="
echo " Joining Node to Kubernetes Cluster (Role: $ROLE)"
echo " Hostname : $(hostname)"
echo " IP       : $(hostname -I | awk '{print $1}')"
echo "=========================================================="

# 1. Ensure node is prepared
if ! command -v kubeadm >/dev/null 2>&1 || ! command -v containerd >/dev/null 2>&1; then
  echo "[1/3] Prerequisites missing. Running 01-prep-node.sh first..."
  bash "$SCRIPT_DIR/01-prep-node.sh"
else
  echo "[1/3] Node packages (containerd, kubelet, kubeadm) already installed."
fi

# 2. Reset previous state if present
if [ -f /etc/kubernetes/kubelet.conf ]; then
  echo "[2/3] Resetting previous cluster join state..."
  kubeadm reset -f || true
  rm -rf /etc/cni/net.d
fi

# 3. Execute Join Command
echo "[3/3] Executing join command..."
if [ -n "$CUSTOM_JOIN_CMD" ]; then
  eval "$CUSTOM_JOIN_CMD"
elif [ "$ROLE" = "worker" ] && [ -f "$PARENT_DIR/join-worker.sh" ]; then
  bash "$PARENT_DIR/join-worker.sh"
elif [ "$ROLE" = "control-plane" ] && [ -f "$PARENT_DIR/join-controlplane.sh" ]; then
  bash "$PARENT_DIR/join-controlplane.sh"
else
  echo "[ERROR] Join command not found!"
  echo "Usage: sudo $0 [worker|control-plane] \"<kubeadm join command>\""
  echo "Example: sudo $0 worker \"kubeadm join 10.10.1.10:6443 --token abc... --discovery-token-ca-cert-hash sha256:...\""
  exit 1
fi

echo "=========================================================="
echo " SUCCESS: Node $(hostname) successfully joined the cluster!"
echo "=========================================================="
