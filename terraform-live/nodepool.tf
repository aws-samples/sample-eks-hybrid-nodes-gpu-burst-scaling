# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

################################################################################
# Karpenter Node Pools
################################################################################

# NodePool - default
resource "kubectl_manifest" "karpenter_node_pool_default" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: default
    spec:
      template:
        metadata:
          labels:
            intent: apps
        spec:
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: default
          requirements:
            - key: "karpenter.k8s.aws/instance-category"
              operator: In
              values: ["c", "m", "r"]
            - key: "karpenter.k8s.aws/instance-cpu"
              operator: In
              values: ["4", "8", "16", "32"]
            - key: "karpenter.k8s.aws/instance-hypervisor"
              operator: In
              values: ["nitro"]
            - key: "karpenter.k8s.aws/instance-generation"
              operator: Gt
              values: ["2"]
            - key: kubernetes.io/arch
              operator: In
              values: ["amd64"]
            - key: kubernetes.io/os
              operator: In
              values: ["linux"]
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["on-demand"]
      disruption:
        consolidationPolicy: WhenEmpty
        consolidateAfter: 30s
      limits:
        cpu: 1000
  YAML

  depends_on = [
    module.eks,
    module.eks.eks_managed_node_groups,
    helm_release.karpenter
  ]
}

# NodePool - orchestration
resource "kubectl_manifest" "karpenter_node_pool_orchestration" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: orchestration
    spec:
      template:
        metadata:
          labels:
            role: orchestration
        spec:
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: orchestration
          requirements:
            - key: kubernetes.io/arch
              operator: In
              values: ["amd64", "arm64"]
            - key: kubernetes.io/os
              operator: In
              values: ["linux"]
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["reserved", "on-demand"]
            - key: karpenter.k8s.aws/instance-family
              operator: In
              values: ["m5", "m6i", "m7", "r6", "m7i"]
            - key: "karpenter.k8s.aws/instance-cpu"
              operator: In
              values: ["4", "8", "16", "32"]
      limits:
        cpu: 2000
        memory: 2000Gi
      disruption:
        consolidationPolicy: WhenEmpty
        consolidateAfter: 600s
  YAML

  depends_on = [
    module.eks,
    module.eks.eks_managed_node_groups,
    helm_release.karpenter
  ]
}

# NodePool - gpu
resource "kubectl_manifest" "karpenter_node_pool_gpu" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: gpu
    spec:
      template:
        metadata:
          labels:
            intent: gpu
            nvidia.com/gpu.present: "true"
        spec:
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: gpu
          taints:
            - key: nvidia.com/gpu
              value: "true"
              effect: NoSchedule
          requirements:
            - key: kubernetes.io/arch
              operator: In
              values: ["amd64"]
            - key: kubernetes.io/os
              operator: In
              values: ["linux"]
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["spot", "on-demand"]
            - key: node.kubernetes.io/instance-type
              operator: In
              values:
                - "g6.xlarge"
                - "g6.2xlarge"
                - "g6.4xlarge"
                - "g6.8xlarge"
                - "g6.12xlarge"
                - "g6.16xlarge"
                - "g6.24xlarge"
                - "g6.48xlarge"
                - "g6e.xlarge"
                - "g6e.2xlarge"
                - "g6e.4xlarge"
                - "g6e.8xlarge"
                - "g6e.12xlarge"
                - "g6e.16xlarge"
                - "g6e.24xlarge"
                - "g6e.48xlarge"
                - "g7e.xlarge"
                - "g7e.2xlarge"
                - "g7e.4xlarge"
                - "g7e.8xlarge"
                - "g7e.12xlarge"
                - "g7e.16xlarge"
                - "g7e.24xlarge"
                - "g7e.48xlarge"
      limits:
        cpu: 256
        nvidia.com/gpu: 16
      disruption:
        consolidationPolicy: WhenEmpty
        consolidateAfter: 600s
  YAML

  depends_on = [
    module.eks,
    module.eks.eks_managed_node_groups,
    helm_release.karpenter
  ]
}

# NodePool - gpu-inference
resource "kubectl_manifest" "karpenter_node_pool_gpu_inference" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: gpu-inference
    spec:
      template:
        metadata:
          labels:
            intent: gpu-inference
            nvidia.com/gpu.present: "true"
        spec:
          expireAfter: 24h
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: gpu-inference
          taints:
            - key: workload-type
              value: gpu-inference
              effect: NoSchedule
          requirements:
            - key: kubernetes.io/arch
              operator: In
              values: ["amd64"]
            - key: kubernetes.io/os
              operator: In
              values: ["linux"]
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["on-demand"]
            - key: node.kubernetes.io/instance-type
              operator: In
              values: ["g7e.4xlarge", "g7e.8xlarge"]
      limits:
        cpu: 512
        nvidia.com/gpu: 32
      disruption:
        consolidationPolicy: WhenEmpty
        consolidateAfter: 600s
  YAML

  depends_on = [
    module.eks,
    module.eks.eks_managed_node_groups,
    helm_release.karpenter
  ]
}

# NodePool - graviton
resource "kubectl_manifest" "karpenter_node_pool_graviton" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: graviton
    spec:
      template:
        metadata:
          labels:
            kubernetes.io/arch: "arm"
        spec:
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: graviton
          taints:
            - key: kubernetes.io/arch
              value: "arm64"
              effect: NoSchedule
          requirements:
            - key: kubernetes.io/arch
              operator: In
              values: ["arm64"]
            - key: kubernetes.io/os
              operator: In
              values: ["linux"]
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["reserved", "on-demand"]
            - key: node.kubernetes.io/instance-type
              operator: In
              values: ["c8g.4xlarge", "c8g.8xlarge"]
      limits:
        cpu: 256
        memory: 1000Gi
      disruption:
        consolidationPolicy: WhenEmpty
        consolidateAfter: 600s
  YAML

  depends_on = [
    module.eks,
    module.eks.eks_managed_node_groups,
    helm_release.karpenter
  ]
}

# NodePool - dynamo
resource "kubectl_manifest" "karpenter_node_pool_dynamo" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: dynamo
    spec:
      template:
        metadata:
          labels:
            optimized: "dynamo"
        spec:
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: dynamo
          requirements:
            - key: kubernetes.io/arch
              operator: In
              values: ["amd64"]
            - key: kubernetes.io/os
              operator: In
              values: ["linux"]
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["on-demand"]
            - key: node.kubernetes.io/instance-type
              operator: In
              values: ["c7i.2xlarge"]
      limits:
        cpu: 32
      disruption:
        consolidationPolicy: WhenEmpty
        consolidateAfter: 30s
  YAML

  depends_on = [
    module.eks,
    module.eks.eks_managed_node_groups,
    helm_release.karpenter
  ]
}

# NodePool - cpu-optimized
resource "kubectl_manifest" "karpenter_node_pool_cpu_optimized" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: cpu-optimized
    spec:
      template:
        metadata:
          labels:
            optimized: "cpu"
        spec:
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: cpu-optimized
          requirements:
            - key: kubernetes.io/arch
              operator: In
              values: ["amd64"]
            - key: kubernetes.io/os
              operator: In
              values: ["linux"]
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["on-demand"]
            - key: node.kubernetes.io/instance-type
              operator: In
              values: ["c8i.2xlarge"]
      limits:
        cpu: 64
        memory: 128Gi
      disruption:
        consolidationPolicy: WhenEmpty
        consolidateAfter: 600s
  YAML

  depends_on = [
    module.eks,
    module.eks.eks_managed_node_groups,
    helm_release.karpenter
  ]
}

# NodePool - optimized-nodes
resource "kubectl_manifest" "karpenter_node_pool_optimized_nodes" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: optimized-nodes
    spec:
      template:
        metadata:
          labels:
            optimized: "memory"
        spec:
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: optimized-nodes
          requirements:
            - key: kubernetes.io/arch
              operator: In
              values: ["amd64"]
            - key: kubernetes.io/os
              operator: In
              values: ["linux"]
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["on-demand"]
            - key: karpenter.k8s.aws/instance-family
              operator: In
              values: ["r8i"]
      limits:
        cpu: 1000
        memory: 1000Gi
      disruption:
        consolidationPolicy: WhenEmpty
        consolidateAfter: 600s
  YAML

  depends_on = [
    module.eks,
    module.eks.eks_managed_node_groups,
    helm_release.karpenter
  ]
}
