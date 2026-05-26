#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# =============================================================================
# Phase 3 — Setup Hybrid Node (NVIDIA drivers + nodeadm + EKS registration)
# =============================================================================
# Purpose:
#   Prepare the EC2 Ubuntu 22.04 instance (g6.12xlarge, 4x NVIDIA L4) to join the
#   EKS cluster `llm-k8sv4` as a Hybrid Node:
#     1. Switch /etc/apt/sources.list to HTTPS (the hybrid SG allows only 443).
#     2. Install GCC 12 (required to build NVIDIA DKMS against kernel 6.8).
#     3. Install NVIDIA driver 570/580-server (works with kernel 6.8).
#     4. Install `nodeadm` from hybrid-assets.eks.amazonaws.com.
#     5. Run `nodeadm install` to provision kubelet / containerd / runtimes.
#     6. Write /etc/nodeadm/nodeConfig.yaml with cluster + SSM hybrid creds.
#     7. Run `nodeadm init` to register the node with the EKS control plane.
#
# Execution model:
#   This script is DESIGNED TO RUN ON THE HYBRID NODE ITSELF. From the
#   operator workstation (outside the VPC) it is delivered via
#   `aws ssm send-command`, because the EKS endpoint is private-only and the
#   instance has no public IP.
#
# Known gotchas (discovered during Phase 3 execution):
#   1. SG hybrid_node allows only outbound 443. Ubuntu `apt` uses port 80 by
#      default → rewrite sources.list to HTTPS.
#   2. Ubuntu 22.04.5 ships with kernel 6.8 (HWE), built with gcc-12. The
#      default gcc-11 cannot build NVIDIA DKMS (error: unrecognized option
#      `-ftrivial-auto-var-init=zero`) → install gcc-12 + make it default.
#   3. NVIDIA driver 550.x DKMS ALSO fails on kernel 6.8. Use the 570-server
#      line (Ubuntu's `nvidia-driver-570-server` is a transitional package
#      for `nvidia-driver-580-server`, which is the version that actually
#      gets installed).
#   4. Running `nodeadm install --credential-provider ssm` replaces the
#      snap-based amazon-ssm-agent with the deb package. This BREAKS active
#      SSM Run Command sessions mid-execution. Plan for connectivity loss
#      between `nodeadm install` and the first `nodeadm init` — the agent
#      will re-register as a managed instance (mi-*) only after `init`.
#
# Prerequisites:
#   - Phase 2 complete (cluster endpoint = Private Only, RemoteNetworkConfig).
#   - SSM hybrid activation created (activationId + activationCode in
#     terraform-outputs.json).
#   - Instance outbound 443 to NVIDIA / Ubuntu / EKS hybrid-assets.
#
# Usage (from operator workstation — do NOT send whole script via SSM; the
# Run Command will lose the shell halfway through step 5. Break into chunks):
#   bash scripts/02-setup-hybrid-node.sh          # on the instance, via
#                                                 # session-manager / SSH
# or equivalent run-command chunks.
# =============================================================================

set -euo pipefail

# --- Configuration -----------------------------------------------------------
CLUSTER_NAME="${CLUSTER_NAME:-llm-k8sv4}"
AWS_REGION="${AWS_REGION:-ap-northeast-1}"
K8S_VERSION="${K8S_VERSION:-1.33}"
# Ubuntu's transitional nvidia-driver-570-server pulls 580-server in the
# -updates pocket — both are kernel-6.8 friendly.
NVIDIA_SERVER_PKG="${NVIDIA_SERVER_PKG:-nvidia-driver-570-server}"
NODEADM_URL="${NODEADM_URL:-https://hybrid-assets.eks.amazonaws.com/releases/latest/bin/linux/amd64/nodeadm}"

# Must be provided by the caller (never hard-code in the repo).
: "${ACTIVATION_CODE:?ACTIVATION_CODE env var is required (terraform output ssm_activation_code)}"
: "${ACTIVATION_ID:?ACTIVATION_ID env var is required (terraform output ssm_activation_id)}"

# --- Helpers -----------------------------------------------------------------
log() { printf '\n[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }

# --- Step 0: Rewrite apt sources to HTTPS (SG allows only 443) ---------------
log "Step 0/8: Switching /etc/apt/sources.list to HTTPS"
if grep -q '^deb http://' /etc/apt/sources.list; then
  sudo cp -n /etc/apt/sources.list /etc/apt/sources.list.orig-http
  sudo sed -i 's,http://,https://,g' /etc/apt/sources.list
fi

# --- Step 1: Install toolchain + NVIDIA driver -------------------------------
log "Step 1/8: Installing gcc-12 + NVIDIA driver (${NVIDIA_SERVER_PKG})"
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends \
  curl ca-certificates gnupg wget \
  "linux-headers-$(uname -r)" \
  gcc-12 g++-12

# Make gcc-12 the default so the NVIDIA DKMS build picks it up.
sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-11 11 || true
sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-12 12 || true
sudo update-alternatives --set    gcc /usr/bin/gcc-12
sudo update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-11 11 || true
sudo update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-12 12 || true
sudo update-alternatives --set    g++ /usr/bin/g++-12

sudo apt-get install -y "${NVIDIA_SERVER_PKG}"

# --- Step 2: Validate GPU ----------------------------------------------------
log "Step 2/8: Validating nvidia-smi"
if ! sudo modprobe nvidia; then
  log "modprobe nvidia failed; a reboot is likely required. Retrying after reboot..."
  exit 1
fi
nvidia-smi

# --- Step 3: Install nodeadm -------------------------------------------------
log "Step 3/8: Installing nodeadm"
sudo curl -fsSLo /usr/local/bin/nodeadm "${NODEADM_URL}"
sudo chmod +x /usr/local/bin/nodeadm
/usr/local/bin/nodeadm --version

# --- Step 4: nodeadm install -------------------------------------------------
# WARNING: on Ubuntu this reinstalls amazon-ssm-agent (snap → deb) which
# can sever the active SSM Run Command channel. Run this step interactively
# (Session Manager or SSH) if possible, or accept that the outer `send-command`
# will be reported as TimedOut/Undeliverable even if the step succeeded.
log "Step 4/8: Running 'nodeadm install ${K8S_VERSION} --credential-provider ssm'"
sudo /usr/local/bin/nodeadm install "${K8S_VERSION}" --credential-provider ssm

# --- Step 5: Write /etc/nodeadm/nodeConfig.yaml ------------------------------
log "Step 5/8: Writing /etc/nodeadm/nodeConfig.yaml"
sudo mkdir -p /etc/nodeadm
sudo tee /etc/nodeadm/nodeConfig.yaml >/dev/null <<EOF
apiVersion: node.eks.aws/v1alpha1
kind: NodeConfig
spec:
  cluster:
    name: ${CLUSTER_NAME}
    region: ${AWS_REGION}
  hybrid:
    ssm:
      activationCode: ${ACTIVATION_CODE}
      activationId: ${ACTIVATION_ID}
EOF
sudo chmod 600 /etc/nodeadm/nodeConfig.yaml

# --- Step 6: nodeadm init ----------------------------------------------------
log "Step 6/8: Running 'nodeadm init'"
sudo /usr/local/bin/nodeadm init -c file:///etc/nodeadm/nodeConfig.yaml

# --- Step 7: Validation ------------------------------------------------------
log "Step 7/8: Validating kubelet status"
sudo systemctl status kubelet --no-pager || true

log "Step 8/8: Listing nodes (only reachable from inside the VPC)"
sudo kubectl --kubeconfig /var/lib/kubelet/kubeconfig get nodes -o wide || true

log "Phase 3 complete. The node will be NotReady until Cilium CNI is installed in Phase 4."
