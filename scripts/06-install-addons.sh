#!/bin/bash
# ==============================================================================
# scripts/06-install-addons.sh
# Production Add-ons: Metrics Server (for HPA) & Dynamic StorageClass
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -f "$PARENT_DIR/cluster.env" ]; then
  # shellcheck source=/dev/null
  source "$PARENT_DIR/cluster.env"
fi

INSTALL_METRICS_SERVER="${INSTALL_METRICS_SERVER:-true}"
INSTALL_LOCAL_STORAGE="${INSTALL_LOCAL_STORAGE:-true}"

export KUBECONFIG=/etc/kubernetes/admin.conf

echo "=========================================================="
echo " Installing Production Kubernetes Add-ons"
echo " Metrics Server : $INSTALL_METRICS_SERVER"
echo " StorageClass   : $INSTALL_LOCAL_STORAGE"
echo "=========================================================="

# ------------------------------------------------------------------------------
# 1. Metrics Server (Enables 'kubectl top nodes/pods' and Horizontal Pod Autoscaling)
# ------------------------------------------------------------------------------
if [ "$INSTALL_METRICS_SERVER" = "true" ]; then
  echo "[1/2] Installing Kubernetes Metrics Server..."
  METRICS_MANIFEST="/tmp/metrics-server.yaml"
  curl -fsSL https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml -o "$METRICS_MANIFEST"

  # Add --kubelet-insecure-tls for kubeadm internal CA compatibility
  if ! grep -q -- '--kubelet-insecure-tls' "$METRICS_MANIFEST"; then
    sed -i '/- args:/a \        - --kubelet-insecure-tls' "$METRICS_MANIFEST"
  fi

  kubectl apply -f "$METRICS_MANIFEST"
  echo "      Metrics Server installed."
fi

# ------------------------------------------------------------------------------
# 2. Dynamic StorageClass (Rancher Local Path Provisioner)
# ------------------------------------------------------------------------------
if [ "$INSTALL_LOCAL_STORAGE" = "true" ]; then
  echo "[2/2] Installing Local-Path Dynamic StorageClass..."
  STORAGE_MANIFEST="/tmp/local-path-storage.yaml"
  curl -fsSL https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml -o "$STORAGE_MANIFEST"

  kubectl apply -f "$STORAGE_MANIFEST"

  # Set as default StorageClass
  kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' 2>/dev/null || true
  echo "      Default StorageClass (local-path) configured."
fi

echo "=========================================================="
echo " PRODUCTION ADD-ONS DEPLOYED!"
echo "=========================================================="
