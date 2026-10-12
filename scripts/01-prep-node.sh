#!/bin/bash
# ==============================================================================
# scripts/01-prep-node.sh
# Universal Node Preparation (Ubuntu/Debian & RHEL/Rocky/AlmaLinux/Amazon Linux)
# Supports both x86_64 (AMD64) and aarch64 (ARM64 / Graviton / Apple Silicon)
# ==============================================================================

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "[ERROR] Please run with sudo or as root: sudo $0"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source cluster configuration if available
if [ -f "$PARENT_DIR/cluster.env" ]; then
  # shellcheck source=/dev/null
  source "$PARENT_DIR/cluster.env"
fi

K8S_VERSION="${K8S_VERSION:-v1.32}"

# Detect OS and Architecture
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)  DEB_ARCH="amd64"; RPM_ARCH="x86_64" ;;
  aarch64) DEB_ARCH="arm64"; RPM_ARCH="aarch64" ;;
  *)       echo "[ERROR] Unsupported architecture: $ARCH"; exit 1 ;;
esac

. /etc/os-release
OS_FAMILY="unknown"
case "$ID" in
  ubuntu|debian)
    OS_FAMILY="debian"
    ;;
  rhel|centos|rocky|almalinux|fedora|amzn)
    OS_FAMILY="rhel"
    ;;
  *)
    if [ -f /etc/debian_version ]; then OS_FAMILY="debian"; fi
    if [ -f /etc/redhat-release ]; then OS_FAMILY="rhel"; fi
    ;;
esac

echo "=========================================================="
echo " Preparing Node for Production Kubernetes"
echo " OS Family     : $OS_FAMILY ($PRETTY_NAME)"
echo " Architecture  : $ARCH ($DEB_ARCH)"
echo " K8s Version   : $K8S_VERSION"
echo "=========================================================="

# ------------------------------------------------------------------------------
# 1. Disable Swap (Kubernetes Requirement)
# ------------------------------------------------------------------------------
echo "[1/7] Disabling swap..."
swapoff -a || true
if grep -q swap /etc/fstab; then
  sed -i.bak -r '/\sswap\s/s/^#?/#/' /etc/fstab
fi
# Mask systemd swap target if active
systemctl mask swap.target 2>/dev/null || true

# ------------------------------------------------------------------------------
# 2. SELinux Handling (RHEL / Rocky / AlmaLinux)
# ------------------------------------------------------------------------------
if command -v getenforce >/dev/null 2>&1; then
  echo "[2/7] Configuring SELinux to permissive mode..."
  setenforce 0 2>/dev/null || true
  if [ -f /etc/selinux/config ]; then
    sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
  fi
else
  echo "[2/7] SELinux not detected or not enforcing."
fi

# ------------------------------------------------------------------------------
# 3. Load Kernel Modules
# ------------------------------------------------------------------------------
echo "[3/7] Loading kernel modules (overlay, br_netfilter)..."
cat <<EOF > /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

# ------------------------------------------------------------------------------
# 4. Configure Sysctl Parameters
# ------------------------------------------------------------------------------
echo "[4/7] Applying sysctl bridge & packet forwarding parameters..."
cat <<EOF > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
net.netfilter.nf_conntrack_max      = 1000000
EOF

sysctl --system > /dev/null

# ------------------------------------------------------------------------------
# 5. Firewall Configuration (UFW or firewalld)
# ------------------------------------------------------------------------------
echo "[5/7] Configuring firewall rules for Kubernetes..."
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  echo "      Configuring UFW rules..."
  ufw allow 6443/tcp comment 'K8s API Server' || true
  ufw allow 2379:2380/tcp comment 'etcd client/peer' || true
  ufw allow 10250/tcp comment 'Kubelet API' || true
  ufw allow 10257/tcp comment 'Kube-controller-manager' || true
  ufw allow 10259/tcp comment 'Kube-scheduler' || true
  ufw allow 10256/tcp comment 'Kube-proxy' || true
  ufw allow 30000:32767/tcp comment 'NodePort Services' || true
  ufw allow 4789/udp comment 'Calico VXLAN' || true
  ufw allow 179/tcp comment 'Calico BGP' || true
elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  echo "      Configuring firewalld rules..."
  firewall-cmd --permanent --add-port=6443/tcp
  firewall-cmd --permanent --add-port=2379-2380/tcp
  firewall-cmd --permanent --add-port=10250/tcp
  firewall-cmd --permanent --add-port=10257/tcp
  firewall-cmd --permanent --add-port=10259/tcp
  firewall-cmd --permanent --add-port=10256/tcp
  firewall-cmd --permanent --add-port=30000-32767/tcp
  firewall-cmd --permanent --add-port=4789/udp
  firewall-cmd --permanent --add-port=179/tcp
  firewall-cmd --reload
fi

# ------------------------------------------------------------------------------
# 6. Install & Configure Container Runtime (Containerd)
# ------------------------------------------------------------------------------
echo "[6/7] Installing containerd.io runtime..."
if [ "$OS_FAMILY" = "debian" ]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/$ID/gpg" | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  UBUNTU_CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-$UBUNTU_CODENAME}")"
  echo "deb [arch=$DEB_ARCH signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$ID $UBUNTU_CODENAME stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -y
  apt-get install -y containerd.io
elif [ "$OS_FAMILY" = "rhel" ]; then
  yum install -y yum-utils device-mapper-persistent-data lvm2
  yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo || true
  yum install -y containerd.io
fi

echo "      Configuring containerd with SystemdCgroup = true..."
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

systemctl daemon-reload
systemctl restart containerd
systemctl enable containerd

# ------------------------------------------------------------------------------
# 7. Install Kubernetes Packages (kubelet, kubeadm, kubectl)
# ------------------------------------------------------------------------------
echo "[7/7] Installing Kubernetes packages ($K8S_VERSION)..."
if [ "$OS_FAMILY" = "debian" ]; then
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/$K8S_VERSION/deb/Release.key" | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  chmod a+r /etc/apt/keyrings/kubernetes-apt-keyring.gpg

  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$K8S_VERSION/deb/ /" \
    > /etc/apt/sources.list.d/kubernetes.list

  apt-get update -y
  apt-get install -y kubelet kubeadm kubectl
  apt-mark hold kubelet kubeadm kubectl
elif [ "$OS_FAMILY" = "rhel" ]; then
  cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/$K8S_VERSION/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/$K8S_VERSION/rpm/repodata/repomd.xml.key
EOF

  yum install -y kubelet kubeadm kubectl
  yum install -y yum-plugin-versionlock 2>/dev/null || true
  yum versionlock add kubelet kubeadm kubectl 2>/dev/null || true
fi

systemctl enable --now kubelet

echo "=========================================================="
echo " SUCCESS: Node preparation completed successfully!"
echo " Containerd: $(containerd --version)"
echo " Kubelet   : $(kubelet --version)"
echo "=========================================================="
