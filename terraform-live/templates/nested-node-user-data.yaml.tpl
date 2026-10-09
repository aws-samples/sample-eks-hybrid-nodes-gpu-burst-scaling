#cloud-config
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# cloud-init (NoCloud) for the Ubuntu VM that runs INSIDE Hyper-V on the nested
# virtualization host (onprem_mode = "nested-hyperv"). Rendered by Terraform,
# delivered to the host through the private artifact bucket and written to a
# FAT32 "CIDATA" seed disk by the setup automation.
#
# The VM self-joins the EKS cluster as a hybrid node at first boot, with the
# same nodeadm + SSM activation flow a vSphere VM uses (scripts/onprem-node-bootstrap.sh).
hostname: ${vm_name}
bootcmd:
  # A real data center has no instance metadata service. Without this block the
  # VM reaches the HOST's IMDS through the Hyper-V routing, and the SSM agent
  # prefers IMDS over the hybrid activation: it takes over the Windows host's
  # i-* identity. Block it before any agent is installed.
  - iptables -C OUTPUT -d 169.254.169.254 -j DROP 2>/dev/null || iptables -I OUTPUT -d 169.254.169.254 -j DROP
ssh_pwauth: false
write_files:
  - path: /etc/netplan/60-static.yaml
    permissions: '0600'
    content: |
      network:
        version: 2
        ethernets:
          eth0:
            match: {name: "e*"}
            addresses: [${vm_ip}/${node_prefix}]
            routes: [{to: default, via: ${gateway_ip}}]
            nameservers: {addresses: [8.8.8.8, 1.1.1.1]}
  - path: /etc/systemd/system/block-imds.service
    content: |
      [Unit]
      Description=Block IMDS (a simulated data center has no metadata service)
      Before=network-online.target
      [Service]
      Type=oneshot
      ExecStart=/bin/sh -c 'iptables -C OUTPUT -d 169.254.169.254 -j DROP 2>/dev/null || iptables -I OUTPUT -d 169.254.169.254 -j DROP'
      RemainAfterExit=yes
      [Install]
      WantedBy=multi-user.target
  - path: /etc/eks/nodeadm-config.yaml
    permissions: '0600'
    content: |
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
  # The join runs as a systemd unit, not a cloud-init runcmd: runcmd is
  # synchronous and never retries, while Restart=on-failure keeps trying until
  # the node really is part of the cluster (egress may still be converging when
  # the VM first boots, and IAM propagation can delay eks:ListAccessEntries).
  - path: /usr/local/bin/join-cluster.sh
    permissions: '0755'
    content: |
      #!/usr/bin/env bash
      set -uo pipefail
      exec >> /var/log/join-cluster.log 2>&1
      echo "=== join attempt $(date -Is) ==="
      if systemctl is-active --quiet kubelet; then
        echo "kubelet already active - nothing to do"; exit 0
      fi
      for i in $(seq 1 30); do
        if curl -fsS --max-time 10 -o /dev/null https://hybrid-assets.eks.amazonaws.com/releases/latest/bin/linux/amd64/nodeadm; then
          echo "egress OK after $i probe(s)"; break
        fi
        echo "no egress yet (probe $i/30)"; sleep 10
      done
      if ! command -v nodeadm >/dev/null; then
        curl -fsSL --retry 5 --retry-delay 10 --retry-connrefused \
          -o /tmp/nodeadm https://hybrid-assets.eks.amazonaws.com/releases/latest/bin/linux/amd64/nodeadm \
          || { echo "nodeadm download failed - systemd will retry"; exit 1; }
        install -m 0755 /tmp/nodeadm /usr/local/bin/nodeadm
      fi
      if [ ! -x /usr/bin/kubelet ] && [ ! -x /usr/local/bin/kubelet ]; then
        nodeadm install ${k8s_version} --credential-provider ssm || { echo "nodeadm install failed - retry"; exit 1; }
      fi
      nodeadm init --config-source file:///etc/eks/nodeadm-config.yaml || { echo "nodeadm init failed - retry"; exit 1; }
      systemctl is-active --quiet kubelet || { echo "kubelet not active after init - retry"; exit 1; }
      echo "JOIN_OK: kubelet active"
  - path: /etc/systemd/system/eks-hybrid-join.service
    content: |
      [Unit]
      Description=Join this VM to the EKS cluster as a hybrid node
      After=network-online.target cloud-final.service block-imds.service
      Wants=network-online.target
      [Service]
      Type=oneshot
      RemainAfterExit=yes
      ExecStart=/usr/local/bin/join-cluster.sh
      Restart=on-failure
      RestartSec=30
      TimeoutStartSec=1800
      [Install]
      WantedBy=multi-user.target
runcmd:
  - netplan apply
  - systemctl daemon-reload
  - systemctl enable block-imds.service
  - systemctl enable --no-block eks-hybrid-join.service
  - systemctl start --no-block eks-hybrid-join.service
