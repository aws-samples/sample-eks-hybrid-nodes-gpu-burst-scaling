#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# Bootstrap an on-premises VMware vSphere VM as an EKS Hybrid Node (CPU baseline).
# Run as root ON THE VM. Supply the Terraform outputs as environment variables:
#
#   sudo CLUSTER_NAME=<cluster_name> REGION=<region> \
#        ACTIVATION_ID=<ssm_activation_id> ACTIVATION_CODE=<ssm_activation_code> \
#        bash onprem-node-bootstrap.sh
#
# This is the CPU equivalent of the upstream EC2 user-data: it installs nodeadm,
# registers the node via SSM activation, and starts kubelet. NO NVIDIA steps —
# the on-premises baseline runs the small LLM (Qwen2.5-1.5B) on CPU.

set -uxo pipefail
exec > >(tee /var/log/onprem-node-bootstrap.log) 2>&1
export DEBIAN_FRONTEND=noninteractive

: "${CLUSTER_NAME:?set CLUSTER_NAME}"
: "${REGION:?set REGION}"
: "${ACTIVATION_ID:?set ACTIVATION_ID}"
: "${ACTIVATION_CODE:?set ACTIVATION_CODE}"
K8S_VERSION="${K8S_VERSION:-1.35}"

# -----------------------------------------------------------------------------
# Phase 1: Install nodeadm
# -----------------------------------------------------------------------------
curl -fsSLo /usr/local/bin/nodeadm \
  https://hybrid-assets.eks.amazonaws.com/releases/latest/bin/linux/amd64/nodeadm
chmod +x /usr/local/bin/nodeadm

# -----------------------------------------------------------------------------
# Phase 2: nodeadm install (kubelet, containerd, SSM agent)
# -----------------------------------------------------------------------------
/usr/local/bin/nodeadm install "${K8S_VERSION}" --credential-provider ssm

# -----------------------------------------------------------------------------
# Phase 3: Configure nodeadm with the SSM activation
# -----------------------------------------------------------------------------
mkdir -p /etc/eks
cat > /etc/eks/nodeadm-config.yaml <<EOF
apiVersion: node.eks.aws/v1alpha1
kind: NodeConfig
spec:
  cluster:
    name: ${CLUSTER_NAME}
    region: ${REGION}
  hybrid:
    ssm:
      activationId: ${ACTIVATION_ID}
      activationCode: ${ACTIVATION_CODE}
EOF

# -----------------------------------------------------------------------------
# Phase 4: Initialize the node (registers with EKS, starts kubelet)
# Retry loop handles IAM propagation delay for eks:ListAccessEntries
# -----------------------------------------------------------------------------
for i in $(seq 1 5); do
  echo "=== nodeadm init attempt $i of 5 ==="
  if /usr/local/bin/nodeadm init --config-source file:///etc/eks/nodeadm-config.yaml; then
    echo "=== nodeadm init SUCCESS ==="
    break
  else
    echo "=== nodeadm init FAILED (attempt $i) — retrying in 30s ==="
    sleep 30
  fi
done

echo "=== on-premises node bootstrap COMPLETE ==="
echo "Verify from your workstation: kubectl get nodes -o wide"
