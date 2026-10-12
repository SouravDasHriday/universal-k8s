#!/bin/bash
# ==============================================================================
# scripts/05-install-cni.sh
# Production CNI Network Fabric Installer (Calico & Cilium)
# Optimized for AWS Multi-Region VPC Peering / Transit Gateway with MTU Tuning
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -f "$PARENT_DIR/cluster.env" ]; then
  # shellcheck source=/dev/null
  source "$PARENT_DIR/cluster.env"
fi

CNI_PLUGIN="${CNI_PLUGIN:-calico}"
POD_CIDR="${POD_CIDR:-172.16.0.0/16}"
CNI_MTU="${CNI_MTU:-1440}"
NETWORK_INTERFACE="${NETWORK_INTERFACE:-auto}"

echo "=========================================================="
echo " Deploying Production CNI Fabric: $CNI_PLUGIN"
echo " Pod Network CIDR : $POD_CIDR"
echo " CNI MTU Setting  : $CNI_MTU (Tuned for inter-region encapsulation)"
echo " Network Interface: $NETWORK_INTERFACE"
echo "=========================================================="

export KUBECONFIG=/etc/kubernetes/admin.conf

# ------------------------------------------------------------------------------
# 1. Calico CNI Installation
# ------------------------------------------------------------------------------
if [ "$CNI_PLUGIN" = "calico" ]; then
  CALICO_VERSION="v3.29.2"
  CALICO_URL="https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"
  MANIFEST="/tmp/calico-production.yaml"

  echo "[1/3] Downloading Calico manifest ($CALICO_VERSION)..."
  curl -fsSL "$CALICO_URL" -o "$MANIFEST"

  echo "[2/3] Patching Pod CIDR ($POD_CIDR) and MTU ($CNI_MTU)..."
  python3 -c '
with open("'"$MANIFEST"'", "r") as f:
    content = f.read()

# 1. Set Pod Network CIDR
if "# - name: CALICO_IPV4POOL_CIDR" in content:
    content = content.replace(
        "# - name: CALICO_IPV4POOL_CIDR\n#   value: \"192.168.0.0/16\"",
        "- name: CALICO_IPV4POOL_CIDR\n              value: \"'"$POD_CIDR"'\""
    )
elif "value: \"192.168.0.0/16\"" in content:
    content = content.replace("value: \"192.168.0.0/16\"", "value: \"'"$POD_CIDR"'\"")

# 2. Set MTU in ConfigMap to prevent inter-region fragmentation
content = content.replace("\"veth_mtu\": \"1440\"", "\"veth_mtu\": \"'"$CNI_MTU"'\"")
content = content.replace("\"veth_mtu\": \"0\"", "\"veth_mtu\": \"'"$CNI_MTU"'\"")

# 3. Set Interface Autodetection if specified
if "'"$NETWORK_INTERFACE"'" != "auto":
    if "IP_AUTODETECTION_METHOD" not in content:
        content = content.replace(
            "value: \"'"$POD_CIDR"'\"",
            "value: \"'"$POD_CIDR"'\"\n            - name: IP_AUTODETECTION_METHOD\n              value: \"interface='"$NETWORK_INTERFACE"'\""
        )

with open("'"$MANIFEST"'", "w") as f:
    f.write(content)
'

  echo "[3/3] Applying Calico manifest to cluster..."
  kubectl apply -f "$MANIFEST"
  echo "      Calico CNI applied successfully."

# ------------------------------------------------------------------------------
# 2. Cilium CNI Installation (Alternative eBPF fabric)
# ------------------------------------------------------------------------------
elif [ "$CNI_PLUGIN" = "cilium" ]; then
  CILIUM_CLI_VERSION="v0.16.20"
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64)  CLI_ARCH="amd64" ;;
    aarch64) CLI_ARCH="arm64" ;;
  esac

  echo "[1/2] Installing Cilium CLI..."
  curl -fsSL --remote-name-all "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz"
  tar -xzf "cilium-linux-${CLI_ARCH}.tar.gz" -C /usr/local/bin
  rm -f "cilium-linux-${CLI_ARCH}.tar.gz"

  echo "[2/2] Installing Cilium with MTU $CNI_MTU..."
  cilium install \
    --set cluster.name=production-k8s \
    --set ipam.operator.clusterPoolIPv4PodCIDRList="$POD_CIDR" \
    --set mtu="$CNI_MTU"
  echo "      Cilium CNI deployed successfully."
fi

echo "=========================================================="
echo " CNI FABRIC DEPLOYMENT COMPLETE!"
echo "=========================================================="
