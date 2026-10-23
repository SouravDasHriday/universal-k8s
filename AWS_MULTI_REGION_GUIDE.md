# AWS Multi-Region Production Kubernetes Cluster Guide

This guide provides end-to-end instructions for deploying a **production-grade Kubernetes cluster across multiple AWS Regions** connected via **VPC Peering** or **AWS Transit Gateway**, using either **x86_64** or **ARM64 (AWS Graviton)** EC2 instances.

---

## 🌐 1. Architecture & Network Blueprint

```
                      AWS VPC Peering / Transit Gateway
              ┌────────────────────────────────────────────────┐
              │                                                │
   AWS Region A (us-east-1)      AWS Region B (us-west-2)      AWS Region C (eu-west-1)
      VPC: 10.10.0.0/16             VPC: 10.20.0.0/16             VPC: 10.30.0.0/16
 ┌───────────────────────────┐ ┌───────────────────────────┐ ┌───────────────────────────┐
 │ master-us-east-1          │ │ worker-us-west-2          │ │ worker-eu-west-1          │
 │ Private IP: 10.10.1.10    │ │ Private IP: 10.20.1.20    │ │ Private IP: 10.30.1.30    │
 │                           │ └───────────────────────────┘ └───────────────────────────┘
 │ worker-us-east-1          │
 │ Private IP: 10.10.1.11    │
 └───────────────────────────┘
```

### IP Subnet Architecture:
* **AWS VPC Subnets** (Node IPs):
  * Region A (`us-east-1`): `10.10.0.0/16` (Subnet: `10.10.1.0/24`)
  * Region B (`us-west-2`): `10.20.0.0/16` (Subnet: `10.20.1.0/24`)
  * Region C (`eu-west-1`): `10.30.0.0/16` (Subnet: `10.30.1.0/24`)
* **Kubernetes Pod CIDR**: **`172.16.0.0/16`** *(Segregated from AWS VPCs to prevent routing collisions)*
* **Kubernetes Service CIDR**: **`172.20.0.0/16`**
* **Overlay MTU**: **`1440`** *(Tuned for Calico VXLAN over AWS inter-region peering to eliminate packet fragmentation)*

---

## 🛠️ 2. AWS Infrastructure Pre-requisites

### Step 2.1: VPC Peering & Route Tables
1. **Create VPCs**: Ensure each region has a unique, non-overlapping IPv4 CIDR (e.g., `10.10.0.0/16`, `10.20.0.0/16`, `10.30.0.0/16`).
2. **Establish VPC Peering Connections**:
   - `us-east-1` ⇄ `us-west-2`
   - `us-east-1` ⇄ `eu-west-1`
   - `us-west-2` ⇄ `eu-west-1` (optional if worker-to-worker direct communication is required).
3. **Update Route Tables**:
   - In Region A Route Table, add routes:
     - `10.20.0.0/16` ➔ Peering Connection (`pcx-...`)
     - `10.30.0.0/16` ➔ Peering Connection (`pcx-...`)
   - In Region B Route Table, add route:
     - `10.10.0.0/16` ➔ Peering Connection (`pcx-...`)
   - In Region C Route Table, add route:
     - `10.10.0.0/16` ➔ Peering Connection (`pcx-...`)

### Step 2.2: Security Group Configuration
Create a common Security Group (e.g., `k8s-cluster-sg`) in each region allowing inter-region private traffic:

| Type | Protocol | Port Range | Source | Purpose |
| :--- | :--- | :--- | :--- | :--- |
| **Custom TCP** | TCP | `6443` | `10.0.0.0/8` (All VPCs) | Kubernetes API Server |
| **Custom TCP** | TCP | `2379-2380` | `10.10.0.0/16` (Master VPC) | etcd server client API |
| **Custom TCP** | TCP | `10250` | `10.0.0.0/8` (All VPCs) | Kubelet API |
| **Custom TCP** | TCP | `10257` | `10.10.0.0/16` (Master VPC) | Kube-controller-manager |
| **Custom TCP** | TCP | `10259` | `10.10.0.0/16` (Master VPC) | Kube-scheduler |
| **Custom TCP** | TCP | `10256` | `10.0.0.0/8` (All VPCs) | Kube-proxy |
| **Custom UDP** | UDP | `4789` | `10.0.0.0/8` (All VPCs) | Calico VXLAN Cross-Region Overlay |
| **Custom TCP** | TCP | `179` | `10.0.0.0/8` (All VPCs) | Calico BGP Routing |
| **SSH** | TCP | `22` | Your IP | Bastion / Admin Access |
| **All ICMP** | ICMP | All | `10.0.0.0/8` (All VPCs) | Cross-Region Ping Verification |

### Step 2.3: EC2 Instances Provisioning
Launch EC2 instances:
- **Operating System**: Ubuntu 24.04 LTS or Rocky Linux 9
- **Instance Types**:
  - **ARM64 (AWS Graviton)**: `t4g.medium` (2 vCPU, 4GB RAM) or `c7g.large`
  - **x86_64**: `t3.medium` (2 vCPU, 4GB RAM) or `c5.large`
- **Storage**: At least 30 GiB gp3 root volume.
- **Source/Dest Check**:
  - Select each EC2 instance -> **Actions** -> **Networking** -> **Change source/dest check** -> **Stop**.

---

## 🚀 3. Cluster Deployment (Two Ways to Run)

The deployment suite is located at:
`/Users/SD/Desktop/k8s/universal-k8s/`

---

### Option A: Manual Step-by-Step Execution (Recommended for First-Time Setup)

#### Step 1: Copy the Suite to Your EC2 Instances
From your local Mac terminal:
```bash
# Copy to Master in us-east-1
scp -i ~/.ssh/your-aws-key.pem -r /Users/SD/Desktop/k8s/universal-k8s ubuntu@<MASTER_PUBLIC_IP>:~/universal-k8s

# Copy to Worker in us-west-2
scp -i ~/.ssh/your-aws-key.pem -r /Users/SD/Desktop/k8s/universal-k8s ubuntu@<WORKER_REGION_B_PUBLIC_IP>:~/universal-k8s

# Copy to Worker in eu-west-1
scp -i ~/.ssh/your-aws-key.pem -r /Users/SD/Desktop/k8s/universal-k8s ubuntu@<WORKER_REGION_C_PUBLIC_IP>:~/universal-k8s
```

#### Step 2: Initialize Control Plane on Master (Region A)
SSH into your Master EC2 instance:
```bash
ssh -i ~/.ssh/your-aws-key.pem ubuntu@<MASTER_PUBLIC_IP>
cd ~/universal-k8s

# Edit cluster.env to set your Master Private IP
nano cluster.env
# Set: CONTROL_PLANE_ENDPOINT="10.10.1.10" (your master's private IP)
# Set: CERT_SANS="127.0.0.1,localhost,10.10.1.10,<MASTER_PUBLIC_ELASTIC_IP>"

# 1. Run Pre-flight verification
sudo bash scripts/00-preflight.sh

# 2. Prepare OS, Containerd, and Kubernetes packages
sudo bash scripts/01-prep-node.sh

# 3. Initialize Control Plane (generates kubeadm-config.yaml, installs Calico with MTU 1440, and installs Metrics Server)
sudo bash scripts/03-init-controlplane.sh
```

At the end of this script, it displays the worker join command and saves it in `~/universal-k8s/join-worker.sh`.

#### Step 3: Join Worker Nodes from Other Regions (Region B & C)
SSH into each Worker EC2 instance:
```bash
# On Worker in Region B (us-west-2):
ssh -i ~/.ssh/your-aws-key.pem ubuntu@<WORKER_REGION_B_PUBLIC_IP>
cd ~/universal-k8s

# 1. Run Pre-flight verification
sudo bash scripts/00-preflight.sh

# 2. Prepare OS, Containerd, and Kubernetes packages
sudo bash scripts/01-prep-node.sh

# 3. Join the cluster using the Master's private IP (reachable via VPC Peering):
sudo kubeadm join 10.10.1.10:6443 --token <TOKEN> \
    --discovery-token-ca-cert-hash sha256:<HASH>
```

Repeat this command on every worker in any region.

---

### Option B: Automated 1-Click Deployment via `deploy.sh`

If you have a bastion or VPN connection to your AWS VPCs:
1. Open `/Users/SD/Desktop/k8s/universal-k8s/cluster.env`.
2. Populate the `NODES` array with your AWS EC2 private IPs and key path:
   ```bash
   SSH_USER="ubuntu"
   SSH_KEY_PATH="~/.ssh/your-aws-key.pem"
   CONTROL_PLANE_ENDPOINT="10.10.1.10"
   NODES=(
     "master-us-east-1:10.10.1.10:control-plane:us-east-1"
     "worker-us-west-2:10.20.1.20:worker:us-west-2"
     "worker-eu-west-1:10.30.1.30:worker:eu-west-1"
   )
   ```
3. Run the automated deployer from your machine:
   ```bash
   cd /Users/SD/Desktop/k8s/universal-k8s
   ./deploy.sh
   ```

---

## 🔍 4. Verification & Cross-Region Tests

### 1. Check Node Status Across Regions
On the Master node:
```bash
kubectl get nodes -o wide
```
Output:
```text
NAME                 STATUS   ROLES           AGE   VERSION   INTERNAL-IP   OS-IMAGE             KERNEL-VERSION   CONTAINER-RUNTIME
master-us-east-1     Ready    control-plane   10m   v1.32.0   10.10.1.10    Ubuntu 24.04.1 LTS   6.8.0-aws        containerd://1.7.25
worker-us-west-2     Ready    <none>          5m    v1.32.0   10.20.1.20    Ubuntu 24.04.1 LTS   6.8.0-aws        containerd://1.7.25
worker-eu-west-1     Ready    <none>          3m    v1.32.0   10.30.1.30    Ubuntu 24.04.1 LTS   6.8.0-aws        containerd://1.7.25
```

### 2. Verify Cross-Region Pod-to-Pod Communication
Deploy a test daemonset across all regions to verify the overlay network:
```bash
kubectl create deployment ping-test --image=busybox:latest --replicas=3 -- sleep 3600
kubectl get pods -o wide
```

Exec into a pod in Region A and ping a pod in Region B:
```bash
kubectl exec -it <POD_IN_REGION_A> -- ping -c 4 <POD_IP_IN_REGION_B>
```
If you receive replies, your **cross-region CNI with MTU 1440 is fully functional**!

### 3. Verify Metrics Server (Resource Utilization)
```bash
kubectl top nodes
kubectl top pods -A
```
Shows CPU and Memory usage across all AWS regions.

> **Note:** The metrics-server is deployed with `hostNetwork: true` and `--secure-port=4443` to work reliably across multi-region kubeadm clusters. Metrics data may take 60-90 seconds to appear after initial deployment.

### 4. Verify Dynamic StorageClass
```bash
kubectl get storageclass
```
The `local-path` StorageClass will be marked as `(default)`, allowing any PVC to provision local disk storage instantly.
