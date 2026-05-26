# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

################################################################################
# NVIDIA GPU Operator
################################################################################

resource "helm_release" "gpu_operator" {
  name             = "gpu-operator"
  repository       = "https://nvidia.github.io/gpu-operator"
  chart            = "gpu-operator"
  version          = "v26.3.1"
  namespace        = "gpu-operator"
  create_namespace = true
  wait             = true
  timeout          = 600

  values = [
    <<-EOT
    driver:
      enabled: false
    toolkit:
      enabled: false
    devicePlugin:
      enabled: true
    dcgmExporter:
      enabled: true
      hostNetwork: true
      serviceMonitor:
        enabled: true
    gfd:
      enabled: true
    nodeStatusExporter:
      enabled: true
    migManager:
      enabled: false
    operator:
      defaultRuntime: containerd
    tolerations:
      - operator: Exists
    EOT
  ]

  depends_on = [
    module.eks,
    module.eks.eks_managed_node_groups
  ]
}
