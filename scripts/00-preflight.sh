#!/bin/bash
# ==============================================================================
# scripts/00-preflight.sh
# Universal Node Pre-flight Checker (Hardware, OS, Architecture, Network)
# Works across Cloud (AWS/Azure/GCP), On-Premise VMs, and Bare-Metal
# ==============================================================================

set -euo pipefail

echo "=========================================================="
echo " Running Pre-flight Hardware & Environment Verification"
echo "=========================================================="

FAILED=0

# 1. Architecture Detection
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)  K8S_ARCH="amd64" ;;
  aarch64) K8S_ARCH="arm64" ;;
  *)       echo "[ERROR] Unsupported CPU architecture: $ARCH"; exit 1 ;;
esac
echo "  ✓ Architecture       : $ARCH (K8s: $K8S_ARCH)"

# 2. Operating System Detection
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS_ID="$ID"
  OS_VERSION_ID="${VERSION_ID:-}"
  echo "  ✓ Operating System   : $PRETTY_NAME ($OS_ID)"
else
  echo "[ERROR] Cannot detect OS. /etc/os-release not found."
  exit 1
fi

case "$OS_ID" in
  ubuntu|debian)
    PKG_MGR="apt"
    ;;
  rhel|centos|rocky|almalinux|fedora|amzn)
    PKG_MGR="dnf"
    ;;
  *)
    echo "[WARNING] Untested OS: $OS_ID. Supported: Ubuntu, Debian, RHEL, Rocky, AlmaLinux, Amazon Linux 2023."
    PKG_MGR="unknown"
    ;;
esac
echo "  ✓ Package Manager    : $PKG_MGR"

# 3. CPU Core Check (Kubeadm requires >= 2 vCPUs)
CPUS=$(nproc)
if [ "$CPUS" -lt 2 ]; then
  echo "  ✗ [FAIL] CPU Cores   : $CPUS (Minimum 2 vCPUs required for Kubernetes control plane)"
  FAILED=1
else
  echo "  ✓ CPU Cores          : $CPUS vCPUs"
fi

# 4. RAM Check (Minimum 2GB RAM)
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
if [ "$TOTAL_RAM_MB" -lt 1700 ]; then
  echo "  ✗ [FAIL] Total RAM   : ${TOTAL_RAM_MB}MB (Minimum 2048MB required)"
  FAILED=1
else
  echo "  ✓ Total Memory       : ${TOTAL_RAM_MB}MB"
fi

# 5. Disk Space Check (Minimum 10GB free on /var and /)
FREE_DISK_GB=$(df -BG / | awk 'NR==2 {gsub("G",""); print $4}')
if [ "$FREE_DISK_GB" -lt 10 ]; then
  echo "  ✗ [FAIL] Disk Free   : ${FREE_DISK_GB}GB (Minimum 10GB free disk required)"
  FAILED=1
else
  echo "  ✓ Root Disk Free     : ${FREE_DISK_GB}GB"
fi

# 6. Port Availability Check
PORTS_TO_CHECK=(6443 10250)
for port in "${PORTS_TO_CHECK[@]}"; do
  if ss -tuln | grep -q ":$port "; then
    echo "  ✗ [FAIL] Port $port is already in use by another process!"
    FAILED=1
  fi
done

# 7. Summary
if [ "$FAILED" -eq 1 ]; then
  echo "=========================================================="
  echo "[ERROR] Pre-flight verification failed! Please resolve above issues before proceeding."
  exit 1
else
  echo "=========================================================="
  echo " SUCCESS: Node meets all production hardware & OS requirements!"
  echo "=========================================================="
fi
