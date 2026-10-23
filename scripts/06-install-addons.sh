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

  # ── Portable sed helper (macOS vs GNU) ──
  _sed_inplace() {
    if sed --version 2>/dev/null | grep -q GNU; then
      sed -i "$@"
    else
      sed -i '' "$@"
    fi
  }

  # ── Patch 1: Enable hostNetwork so the API server can route to metrics-server ──
  # Insert 'hostNetwork: true' right after the 'containers:' line inside the
  # metrics-server Deployment spec.
  if ! grep -q 'hostNetwork: true' "$METRICS_MANIFEST"; then
    _sed_inplace '/^ *containers:/i\
\        hostNetwork: true' "$METRICS_MANIFEST"
  fi

  # ── Patch 2: Add --kubelet-insecure-tls (accepts kubeadm self-signed certs) ──
  if ! grep -q -- '--kubelet-insecure-tls' "$METRICS_MANIFEST"; then
    _sed_inplace '/- args:/a\
\        - --kubelet-insecure-tls' "$METRICS_MANIFEST"
  fi

  # ── Patch 3: Add --secure-port=4443 (avoids conflict with kubelet on 10250) ──
  if ! grep -q -- '--secure-port=4443' "$METRICS_MANIFEST"; then
    _sed_inplace '/- args:/a\
\        - --secure-port=4443' "$METRICS_MANIFEST"
  fi

  # ── Patch 4: Update containerPort from 10250 → 4443 ──
  _sed_inplace 's/containerPort: 10250/containerPort: 4443/g' "$METRICS_MANIFEST"

  kubectl apply -f "$METRICS_MANIFEST"
  echo "      Metrics Server installed (hostNetwork + port 4443)."
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
