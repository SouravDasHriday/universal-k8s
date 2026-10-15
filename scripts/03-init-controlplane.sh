#!/bin/bash
# ==============================================================================
# scripts/03-init-controlplane.sh
# Declarative Production Control Plane Initializer
# Generates kubeadm-config.yaml, initializes cluster, installs CNI & Addons
# ==============================================================================

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "[ERROR] Please run with sudo or as root: sudo $0"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source cluster configuration
if [ -f "$PARENT_DIR/cluster.env" ]; then
  # shellcheck source=/dev/null
  source "$PARENT_DIR/cluster.env"
fi

K8S_VERSION="${K8S_VERSION:-v1.32}"
POD_CIDR="${POD_CIDR:-172.16.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-172.20.0.0/16}"
CONTROL_PLANE_ENDPOINT="${CONTROL_PLANE_ENDPOINT:-$(hostname -I | awk '{print $1}')}"
CONTROL_PLANE_PORT="${CONTROL_PLANE_PORT:-6443}"
CERT_SANS="${CERT_SANS:-127.0.0.1,localhost}"

# Auto-detect local primary IP
LOCAL_IP="$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || hostname -I | awk '{print $1}')"

# Auto-detect cloud public IP if running on AWS / Azure / GCP
CLOUD_PUBLIC_IP=""
if curl -fsSL --connect-timeout 2 http://169.254.169.254/latest/meta-data/public-ipv4 >/dev/null 2>&1; then
  CLOUD_PUBLIC_IP="$(curl -fsSL --connect-timeout 2 http://169.254.169.254/latest/meta-data/public-ipv4 || true)"
fi

echo "=========================================================="
echo " Initializing Production Kubernetes Control Plane"
echo " Master Local IP        : $LOCAL_IP"
echo " Control Plane Endpoint : $CONTROL_PLANE_ENDPOINT:$CONTROL_PLANE_PORT"
echo " Pod Network CIDR       : $POD_CIDR"
echo " Service Network CIDR   : $SERVICE_CIDR"
if [ -n "$CLOUD_PUBLIC_IP" ]; then
  echo " Detected Cloud Public IP: $CLOUD_PUBLIC_IP"
fi
echo "=========================================================="

# 1. Reset if existing cluster found
if [ -f /etc/kubernetes/admin.conf ]; then
  echo "[WARNING] Existing cluster configuration detected at /etc/kubernetes/admin.conf."
  read -p "Reset existing cluster? (y/N): " -r CONFIRM
  if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
    kubeadm reset -f
    rm -rf /etc/cni/net.d "$HOME/.kube"
  fi
fi

# 2. Build SANs list
SAN_ENTRIES=("$LOCAL_IP" "$CONTROL_PLANE_ENDPOINT" "127.0.0.1" "localhost" "$(hostname)")
if [ -n "$CLOUD_PUBLIC_IP" ]; then
  SAN_ENTRIES+=("$CLOUD_PUBLIC_IP")
fi
IFS=',' read -ra EXTRA_SANS <<< "$CERT_SANS"
for san in "${EXTRA_SANS[@]}"; do
  san_trimmed="$(echo "$san" | xargs)"
  if [ -n "$san_trimmed" ]; then
    SAN_ENTRIES+=("$san_trimmed")
  fi
done

# Deduplicate SANs
UNIQUE_SANS=($(echo "${SAN_ENTRIES[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))

# 3. Generate Declarative kubeadm-config.yaml
CONFIG_FILE="/tmp/kubeadm-config.yaml"
cat <<EOF > "$CONFIG_FILE"
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "${LOCAL_IP}"
  bindPort: 6443
nodeRegistration:
  criSocket: "unix:///run/containerd/containerd.sock"
  imagePullPolicy: IfNotPresent
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: "${K8S_VERSION}.0"
controlPlaneEndpoint: "${CONTROL_PLANE_ENDPOINT}:${CONTROL_PLANE_PORT}"
networking:
  podSubnet: "${POD_CIDR}"
  serviceSubnet: "${SERVICE_CIDR}"
apiServer:
  certSANs:
EOF

for s in "${UNIQUE_SANS[@]}"; do
  echo "    - \"$s\"" >> "$CONFIG_FILE"
done

cat <<EOF >> "$CONFIG_FILE"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: "systemd"
failSwapOn: true
EOF

echo "[1/4] Declarative configuration generated at $CONFIG_FILE"

# 4. Run kubeadm init
echo "[2/4] Running kubeadm init..."
INIT_OUTPUT_FILE="/tmp/kubeadm-init.log"
kubeadm init --config="$CONFIG_FILE" --upload-certs | tee "$INIT_OUTPUT_FILE"

# 5. Configure kubeconfig
echo "[3/4] Configuring admin kubeconfig..."
mkdir -p "$HOME/.kube"
cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"
chown "$(id -u)":"$(id -g)" "$HOME/.kube/config"

if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
  USER_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
  mkdir -p "$USER_HOME/.kube"
  cp -f /etc/kubernetes/admin.conf "$USER_HOME/.kube/config"
  chown -R "$SUDO_USER":"$(id -gn "$SUDO_USER")" "$USER_HOME/.kube"
  echo "      kubeconfig configured for $SUDO_USER: $USER_HOME/.kube/config"
fi

export KUBECONFIG=/etc/kubernetes/admin.conf

# 6. Extract Join Commands
# Using the native kubeadm token command guarantees a clean, single-line output
echo "[4/4] Generating permanent join scripts..."
WORKER_JOIN_CMD="$(kubeadm token create --print-join-command)"

cat <<EOF > "$PARENT_DIR/join-worker.sh"
#!/bin/bash
# ==============================================================================
# Worker Node Join Script
# Run this on ANY worker node with sudo:
# ==============================================================================
sudo $WORKER_JOIN_CMD
EOF
chmod +x "$PARENT_DIR/join-worker.sh"

# Extract Control Plane Join Command (for HA multi-master)
CP_JOIN_CMD="$(grep -A 2 -B 1 'control-plane --certificate-key' "$INIT_OUTPUT_FILE" | head -3 | tr '\n' ' ' | sed 's/\\//g' | sed 's/  */ /g' || true)"
if [ -n "$CP_JOIN_CMD" ]; then
  cat <<EOF > "$PARENT_DIR/join-controlplane.sh"
#!/bin/bash
# ==============================================================================
# Secondary Master (Control-Plane) Join Script for HA
# Run this on additional master nodes with sudo:
# ==============================================================================
sudo $CP_JOIN_CMD
EOF
  chmod +x "$PARENT_DIR/join-controlplane.sh"
fi

# 7. Install CNI (Calico or Cilium)
echo "[4/4] Deploying CNI Network Fabric..."
if [ -f "$SCRIPT_DIR/05-install-cni.sh" ]; then
  bash "$SCRIPT_DIR/05-install-cni.sh"
fi

# 8. Install Add-ons (Metrics Server & StorageClass)
if [ -f "$SCRIPT_DIR/06-install-addons.sh" ]; then
  bash "$SCRIPT_DIR/06-install-addons.sh"
fi

echo "=========================================================="
echo " KUBERNETES CONTROL PLANE INITIALIZATION SUCCESSFUL!"
echo "=========================================================="
echo ""
echo "To join worker nodes from ANY region or cloud, run:"
echo "----------------------------------------------------------"
cat "$PARENT_DIR/join-worker.sh" | grep -v '^#' | grep 'kubeadm join' | sed 's/^/sudo /'
echo "----------------------------------------------------------"
echo ""
echo "Join script saved locally to: $PARENT_DIR/join-worker.sh"
if [ -f "$PARENT_DIR/join-controlplane.sh" ]; then
  echo "HA Master join script saved to: $PARENT_DIR/join-controlplane.sh"
fi
echo "=========================================================="
