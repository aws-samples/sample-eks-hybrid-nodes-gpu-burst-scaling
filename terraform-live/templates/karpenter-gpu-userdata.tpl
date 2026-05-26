MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="//"

--//
Content-Type: text/x-shellscript; charset="us-ascii"

#!/bin/bash
max_concurrent_downloads_per_image=10
max_concurrent_unpacks_per_image=10

sed -i "s/^max_concurrent_downloads_per_image = .*$/max_concurrent_downloads_per_image = $max_concurrent_downloads_per_image/" /etc/soci-snapshotter-grpc/config.toml
sed -i "s/^max_concurrent_unpacks_per_image = .*$/max_concurrent_unpacks_per_image = $max_concurrent_unpacks_per_image/" /etc/soci-snapshotter-grpc/config.toml

--//
Content-Type: application/node.eks.aws

apiVersion: node.eks.aws/v1alpha1
kind: NodeConfig
spec:
  featureGates:
    FastImagePull: true
  containerd:
    config: |
      [plugins."io.containerd.grpc.v1.cri"]
        sandbox_image = "${eks_pause_image}"
--//
