# Universal Production-Grade Kubernetes Cluster Setup

[![Kubernetes](https://img.shields.io/badge/Kubernetes-v1.31%20%7C%20v1.32%20%7C%20v1.36-blue?logo=kubernetes)](https://kubernetes.io/)
[![Architecture](https://img.shields.io/badge/Architecture-ARM64%20%7C%20AMD64-success)]()
[![OS](https://img.shields.io/badge/OS-Ubuntu%20%7C%20Debian%20%7C%20RHEL%20%7C%20Rocky-orange)]()
[![Platform](https://img.shields.io/badge/Platform-AWS%20%7C%20Azure%20%7C%20GCP%20%7C%20VM%20%7C%20BareMetal-purple)]()

A modular, production-hardened Kubernetes deployment suite designed to run identically across **Cloud (AWS, Azure, GCP)**, **Virtual Machines (UTM, VMware, Proxmox, KVM)**, and **Bare-Metal physical servers**. 

Native multi-architecture support for **x86_64** (Intel/AMD) and **aarch64** (ARM64 / AWS Graviton / Apple Silicon), optimized for **AWS Multi-Region clusters** connected via VPC Peering or Transit Gateway.

---

## 🌟 Key Features

* **Universal OS & Architecture Support**:
  * Automatically detects Debian/Ubuntu (`apt`) and RHEL/Rocky Linux/AlmaLinux/Amazon Linux (`dnf`/`yum`).
  * Seamlessly supports **ARM64 (AWS Graviton, Apple Silicon, Ampere)** and **AMD64 (x86_64)**.
* **AWS Multi-Region Optimized**:
  * **MTU 1440**: Specifically tuned for Calico VXLAN over AWS inter-region VPC Peering / Transit Gateway to eliminate packet fragmentation and packet dropouts.
  * **Non-Colliding CIDRs**: Segregated Pod CIDR (`172.16.0.0/16`) and Service CIDR (`172.20.0.0/16`) to guarantee zero routing collisions with AWS VPC subnets (`10.x.x.x`).
  * **Cross-Region Certificate SANs**: Automatic TLS signing for private VPC IPs, public Elastic IPs, and inter-region DNS hostnames.
* **Declarative Kubeadm Architecture**:
  * Uses declarative `kubeadm-config.yaml` rather than fragile CLI flags.
  * Pre-configured with `systemd` cgroup drivers, eviction limits, and automated cluster token distribution.
* **Production Container Runtime**:
  * Containerd v2 / v1.7 with full upstream configuration and `SystemdCgroup = true`.
* **Out-of-the-Box Production Add-ons**:
  * **Metrics Server**: Production-hardened with `hostNetwork: true`, `--secure-port=4443`, `--kubelet-insecure-tls`, and patched `containerPort: 4443` — ensures `kubectl top nodes/pods` and Horizontal Pod Autoscaling (HPA) work out-of-the-box on kubeadm, bare-metal, and cloud clusters.
  * **Dynamic Local-Path StorageClass**: Ready-to-use default StorageClass for persistent volume claims (`PVC`) for stateful workloads (databases, storage).
* **High Availability (HA) Ready**:
  * Supports single-master control planes and multi-master HA via Keepalived/HAProxy or Cloud Load Balancers (AWS NLB, Azure LB).

---

## 📁 Repository Structure

```
universal-k8s/
├── cluster.env                   # Central configuration file (VPC CIDRs, IPs, Roles, MTU, CNI)
├── deploy.sh                     # Automated 1-click remote deployer (runs over SSH)
├── README.md                     # This documentation
├── AWS_MULTI_REGION_GUIDE.md     # In-depth AWS Multi-Region architecture & operations guide
└── scripts/
    ├── 00-preflight.sh           # Hardware validation (CPU >= 2, RAM >= 2GB, disk, ports)
    ├── 01-prep-node.sh           # OS & Containerd installer (Ubuntu/Debian + RHEL/Rocky, ARM64 + AMD64)
    ├── 02-setup-ha-lb.sh         # Keepalived + HAProxy helper for Bare-Metal/VM multi-master VIP
    ├── 03-init-controlplane.sh   # Declarative kubeadm init with kubeadm-config.yaml
    ├── 04-join-node.sh           # Universal node joiner (Control plane & Worker nodes)
    ├── 05-install-cni.sh         # Multi-region Calico/Cilium installer with MTU tuning (1440)
    └── 06-install-addons.sh      # Installs Metrics Server (hostNetwork + port 4443) and Local-Path StorageClass
```

---

## 🚀 Quickstart Guide

### 1. Clone the Repository
Clone onto your master server or worker servers:
```bash
git clone <YOUR_GIT_REPO_URL>
cd universal-k8s
```

### 2. Configure Cluster Parameters
Edit `cluster.env` to match your network:
```bash
nano cluster.env
```
Key settings:
```bash
# Master Private IP (or Load Balancer VIP / DNS)
CONTROL_PLANE_ENDPOINT="10.10.1.10"

# Pod CIDR (Must not overlap with host/VPC subnets)
POD_CIDR="172.16.0.0/16"

# CNI MTU (1440 recommended for AWS VPC Peering / Transit Gateway)
CNI_MTU="1440"

# Add any public IPs or custom domain names for API Server TLS certificate
CERT_SANS="127.0.0.1,localhost,10.10.1.10,<OPTIONAL_PUBLIC_IP>"
```

---

### 3. Initialize Control Plane (Master Node)
On the **Master server**:
```bash
# 1. Run pre-flight check
sudo bash scripts/00-preflight.sh

# 2. Prepare OS, Containerd, and Kubernetes tools
sudo bash scripts/01-prep-node.sh

# 3. Initialize Control Plane, CNI (Calico/Cilium), and Add-ons
sudo bash scripts/03-init-controlplane.sh
```

At the end of this script, it will print your unique `kubeadm join` command and save it to `join-worker.sh`.

---

### 4. Join Worker Nodes
On each **Worker server** (in any AWS region, cloud, or VM):
```bash
# 1. Prepare OS and Containerd
sudo bash scripts/01-prep-node.sh

# 2. Join the cluster using the command printed by the Master:
sudo kubeadm join <MASTER_PRIVATE_IP>:6443 --token <TOKEN> \
    --discovery-token-ca-cert-hash sha256:<HASH>
```

---

## ⚡ Option: 1-Click Automated Deployment via `deploy.sh`

If deploying from your laptop or a bastion host with SSH access to all nodes:
1. Define your nodes in `cluster.env`:
   ```bash
   SSH_USER="ubuntu"
   SSH_KEY_PATH="~/.ssh/your-key.pem"
   CONTROL_PLANE_ENDPOINT="10.10.1.10"
   NODES=(
     "master-us-east-1:10.10.1.10:control-plane:us-east-1"
     "worker-us-west-2:10.20.1.20:worker:us-west-2"
     "worker-eu-west-1:10.30.1.30:worker:eu-west-1"
   )
   ```
2. Run the deployer:
   ```bash
   ./deploy.sh
   ```

---

## 🔍 Verification & Health Checks

From the **Master node**:

### Check Nodes Across All Regions
```bash
kubectl get nodes -o wide
```
*Expected: All nodes show `Ready` with their respective kernel and container runtime versions.*

### Check System Pods & Add-ons
```bash
kubectl get pods -A
```
*Expected: CoreDNS, Calico, kube-proxy, metrics-server, and local-path-provisioner are all `1/1 Running`.*

### Test Resource Metrics
```bash
kubectl top nodes
kubectl top pods -A
```
> **Note:** Metrics data may take 60-90 seconds to appear after initial deployment. If `kubectl top` returns `error: metrics not available yet`, wait and retry.

### Test Dynamic Storage Provisioning
```bash
kubectl get storageclass
```
*Expected: `local-path (default)` is ready to dynamically fulfill PersistentVolumeClaims (`PVC`).*

---

## 🌐 AWS Multi-Region Deployment Guide

For full architectural blueprints, AWS Route Table configurations, Security Group rules, and cross-region pod ping tests, see [AWS_MULTI_REGION_GUIDE.md](AWS_MULTI_REGION_GUIDE.md).

---

## 🛠️ Troubleshooting

### Metrics Server Not Reporting Data
If `kubectl top nodes` shows `error: metrics not available yet` after 2+ minutes:
```bash
# Check metrics-server pod status
kubectl -n kube-system get pods -l k8s-app=metrics-server

# Check metrics-server logs
kubectl -n kube-system logs -l k8s-app=metrics-server --tail=50

# Verify the metrics API is registered
kubectl get apiservices | grep metrics
```
The `06-install-addons.sh` script automatically patches the upstream manifest with:
| Patch | Purpose |
|---|---|
| `hostNetwork: true` | Allows API server to route directly to the metrics-server pod |
| `--kubelet-insecure-tls` | Accepts kubeadm self-signed kubelet certificates |
| `--secure-port=4443` | Avoids port 10250 conflict with the kubelet |
| `containerPort: 4443` | Ensures the Service endpoints match the listening port |

---

## 📄 License
MIT License. Free to use, adapt, and distribute for personal, lab, and commercial production environments.
