#!/bin/bash
# ==============================================================================
# universal-k8s/deploy.sh
# Universal Multi-Region Kubernetes Automated Deployer
# Orchestrates deployment across AWS, Azure, GCP, VMs, or Bare-Metal over SSH
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source configuration
if [ ! -f "$SCRIPT_DIR/cluster.env" ]; then
  echo "[ERROR] Configuration file '$SCRIPT_DIR/cluster.env' not found!"
  exit 1
fi

# shellcheck source=/dev/null
source "$SCRIPT_DIR/cluster.env"

echo "=========================================================="
echo " Universal Production Kubernetes Automated Deployer"
echo " Cluster Name : $CLUSTER_NAME"
echo " K8s Version  : $K8S_VERSION"
echo " Pod CIDR     : $POD_CIDR"
echo " CNI Plugin   : $CNI_PLUGIN (MTU: $CNI_MTU)"
echo "=========================================================="

# Check if NODES array is populated
if [ -z "${NODES:-}" ]; then
  echo ""
  echo "[INFO] No NODES array configured in cluster.env."
  echo "       You can either:"
  echo "       1. Define your node IPs in cluster.env to use automated SSH orchestration,"
  echo "       OR"
  echo "       2. Execute the scripts manually on each server as detailed in AWS_MULTI_REGION_GUIDE.md."
  echo ""
  echo "To run manually:"
  echo " - On Master : sudo bash scripts/01-prep-node.sh && sudo bash scripts/03-init-controlplane.sh"
  echo " - On Workers: sudo bash scripts/01-prep-node.sh && sudo bash join-worker.sh"
  exit 0
fi

# 1. Connectivity Check
echo "[1/5] Checking SSH access to all nodes..."
for node_entry in "${NODES[@]}"; do
  IFS=':' read -r node_host node_ip node_role node_region <<< "$node_entry"
  echo "  Connecting to $node_host ($node_ip in $node_region)..."
  if ! ssh -q -o BatchMode=yes -o ConnectTimeout=5 -i "${SSH_KEY_PATH/#\~/$HOME}" "$SSH_USER@$node_ip" 'exit' 2>/dev/null; then
    echo "[ERROR] Cannot reach $node_host ($node_ip) via SSH. Check SSH_KEY_PATH and Security Groups."
    exit 1
  fi
  echo "  ✓ $node_host is reachable"
done

# 2. Distribute Scripts to All Nodes
echo ""
echo "[2/5] Distributing deployment suite to all nodes..."
for node_entry in "${NODES[@]}"; do
  IFS=':' read -r node_host node_ip node_role node_region <<< "$node_entry"
  echo "  -> Copying suite to $node_host ($node_ip)..."
  ssh -i "${SSH_KEY_PATH/#\~/$HOME}" "$SSH_USER@$node_ip" "mkdir -p ~/universal-k8s"
  scp -r -q -i "${SSH_KEY_PATH/#\~/$HOME}" "$SCRIPT_DIR/"* "$SSH_USER@$node_ip:~/universal-k8s/"
  ssh -i "${SSH_KEY_PATH/#\~/$HOME}" "$SSH_USER@$node_ip" "chmod +x ~/universal-k8s/scripts/*.sh"
done

# 3. Prepare All Nodes (Preflight & OS Prep)
echo ""
echo "[3/5] Preparing OS & container runtime on all nodes..."
for node_entry in "${NODES[@]}"; do
  IFS=':' read -r node_host node_ip node_role node_region <<< "$node_entry"
  echo "  -> Preparing $node_host ($node_role)..."
  ssh -t -i "${SSH_KEY_PATH/#\~/$HOME}" "$SSH_USER@$node_ip" \
    "cd ~/universal-k8s && sudo bash scripts/00-preflight.sh && sudo bash scripts/01-prep-node.sh"
done

# 4. Initialize Primary Control Plane
echo ""
echo "[4/5] Initializing Primary Control Plane on $CONTROL_PLANE_ENDPOINT..."
PRIMARY_MASTER_IP="$CONTROL_PLANE_ENDPOINT"
ssh -t -i "${SSH_KEY_PATH/#\~/$HOME}" "$SSH_USER@$PRIMARY_MASTER_IP" \
  "cd ~/universal-k8s && sudo bash scripts/03-init-controlplane.sh"

# Download generated join scripts from Master
echo "  -> Fetching join scripts from primary master..."
scp -i "${SSH_KEY_PATH/#\~/$HOME}" "$SSH_USER@$PRIMARY_MASTER_IP:~/universal-k8s/join-worker.sh" "$SCRIPT_DIR/join-worker.sh"
if ssh -i "${SSH_KEY_PATH/#\~/$HOME}" "$SSH_USER@$PRIMARY_MASTER_IP" "test -f ~/universal-k8s/join-controlplane.sh"; then
  scp -i "${SSH_KEY_PATH/#\~/$HOME}" "$SSH_USER@$PRIMARY_MASTER_IP:~/universal-k8s/join-controlplane.sh" "$SCRIPT_DIR/join-controlplane.sh"
fi

# 5. Join Worker Nodes (and secondary control planes if HA)
echo ""
echo "[5/5] Joining worker nodes across all regions..."
for node_entry in "${NODES[@]}"; do
  IFS=':' read -r node_host node_ip node_role node_region <<< "$node_entry"
  if [ "$node_role" = "worker" ]; then
    echo "  -> Joining $node_host ($node_ip in $node_region)..."
    scp -i "${SSH_KEY_PATH/#\~/$HOME}" "$SCRIPT_DIR/join-worker.sh" "$SSH_USER@$node_ip:~/universal-k8s/join-worker.sh"
    ssh -t -i "${SSH_KEY_PATH/#\~/$HOME}" "$SSH_USER@$node_ip" "cd ~/universal-k8s && sudo bash scripts/04-join-node.sh worker"
  fi
done

echo ""
echo "=========================================================="
echo " MULTI-REGION KUBERNETES CLUSTER DEPLOYED!"
echo "=========================================================="
ssh -i "${SSH_KEY_PATH/#\~/$HOME}" "$SSH_USER@$PRIMARY_MASTER_IP" "kubectl get nodes -o wide"
echo ""
echo "To copy kubeconfig to your local machine:"
echo "  scp -i $SSH_KEY_PATH $SSH_USER@$PRIMARY_MASTER_IP:~/.kube/config ~/.kube/config-$CLUSTER_NAME"
echo "=========================================================="
