# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

################################################################################
# Cilium CNI for Hybrid Nodes
################################################################################

resource "helm_release" "cilium" {
  name       = "cilium"
  repository = "oci://public.ecr.aws/eks/cilium"
  chart      = "cilium"
  version    = "1.17.13-1"
  namespace  = "kube-system"
  wait       = true
  timeout    = 600

  values = [
    <<-EOT
    upgradeCompatibility: "1.16"
    k8sServiceHost: ${replace(module.eks.cluster_endpoint, "https://", "")}
    k8sServicePort: "443"
    ipam:
      mode: cluster-pool
      operator:
        clusterPoolIPv4PodCIDRList:
          - "10.200.0.0/16"
        clusterPoolIPv4MaskSize: 25
    routingMode: tunnel
    tunnelProtocol: vxlan
    vtep:
      enabled: true
    l7Proxy: false
    bpf:
      masquerade: true
    enableIPv4Masquerade: true
    nodePort:
      enabled: true
    operator:
      rollOutPods: true
      unmanagedPodWatcher:
        restart: false
    affinity:
      nodeAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          nodeSelectorTerms:
            - matchExpressions:
                - key: eks.amazonaws.com/compute-type
                  operator: In
                  values:
                    - hybrid
    tolerations:
      - operator: Exists
    EOT
  ]

  depends_on = [
    module.eks,
    module.eks.eks_managed_node_groups
  ]
}
