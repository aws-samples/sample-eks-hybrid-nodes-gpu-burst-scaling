#!/bin/bash
exec > >(tee /var/log/user-data.log) 2>&1
set -uxo pipefail

export DEBIAN_FRONTEND=noninteractive

# =============================================================================
# Phase 1: Install nodeadm
# =============================================================================
curl -fsSLo /usr/local/bin/nodeadm https://hybrid-assets.eks.amazonaws.com/releases/latest/bin/linux/amd64/nodeadm
chmod +x /usr/local/bin/nodeadm

# =============================================================================
# Phase 2: nodeadm install (installs kubelet, containerd, SSM agent)
# =============================================================================
/usr/local/bin/nodeadm install 1.35 --credential-provider ssm

# =============================================================================
# Phase 3: Configure nodeadm
# =============================================================================
mkdir -p /etc/eks
cat > /etc/eks/nodeadm-config.yaml <<EOF
apiVersion: node.eks.aws/v1alpha1
kind: NodeConfig
spec:
  cluster:
    name: ${cluster_name}
    region: ${region}
  hybrid:
    ssm:
      activationId: ${activation_id}
      activationCode: ${activation_code}
EOF

# =============================================================================
# Phase 4: NVIDIA drivers + Container Toolkit
# MUST run BEFORE nodeadm init so containerd has nvidia runtime configured
# when kubelet starts. nodeadm init will NOT overwrite /etc/containerd/conf.d/
# =============================================================================
(
  set -e
  apt-get update -y
  apt-get install -y --no-install-recommends linux-headers-$(uname -r) gcc-12 g++-12
  update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-12 12
  update-alternatives --set gcc /usr/bin/gcc-12
  apt-get install -y nvidia-driver-570-server

  # NVIDIA Container Toolkit
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --batch --yes --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update -y
  apt-get install -y nvidia-container-toolkit
  modprobe nvidia || echo "WARN: modprobe nvidia failed, reboot may be needed"
) || echo "WARN: NVIDIA driver install failed — fix later via SSM"

echo "=== NVIDIA drivers installed ==="

# =============================================================================
# Phase 5: Initialize the node (registers with EKS, starts kubelet)
# Retry loop handles IAM propagation delay for eks:ListAccessEntries
# =============================================================================
MAX_RETRIES=5
RETRY_DELAY=30
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

# =============================================================================
# Phase 6: Configure NVIDIA runtime in containerd AFTER nodeadm init
# nodeadm writes /etc/containerd/config.toml but nvidia-ctk writes to
# /etc/containerd/conf.d/99-nvidia.toml which takes precedence.
# Restart containerd to pick up the nvidia runtime.
# =============================================================================
nvidia-ctk runtime configure --runtime=containerd --set-as-default 2>/dev/null || true
systemctl restart containerd 2>/dev/null || true
sleep 3

echo "=== FULL user-data COMPLETE ==="
