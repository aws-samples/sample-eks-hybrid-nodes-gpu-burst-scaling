# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

################################################################################
# KEDA - Kubernetes Event-Driven Autoscaling
################################################################################

# IMPORTANT: Apply CRDs manually before terraform apply:
# kubectl apply --server-side -f https://github.com/kedacore/keda/releases/download/v2.17.0/keda-2.17.0-crds.yaml

resource "helm_release" "keda" {
  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  version          = "2.17.0"
  namespace        = "keda"
  create_namespace = true
  wait             = true
  timeout          = 300

  values = [
    <<-EOT
    nodeSelector:
      karpenter.sh/controller: "true"
    prometheus:
      metricServer:
        enabled: true
      operator:
        enabled: true
        serviceMonitor:
          enabled: true
    EOT
  ]

  depends_on = [
    module.eks,
    module.eks.eks_managed_node_groups,
    helm_release.kube_prometheus_stack
  ]
}
