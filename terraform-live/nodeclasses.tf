# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

################################################################################
# Karpenter Node Classes
################################################################################

# Karpenter NodeClass - default
resource "kubectl_manifest" "karpenter_node_class_default" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: default
    spec:
      amiSelectorTerms:
        - alias: al2023@latest

      role: ${module.karpenter.node_iam_role_name}

      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${module.eks.cluster_name}

      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${module.eks.cluster_name}

      tags:
        karpenter.sh/discovery: ${module.eks.cluster_name}

      blockDeviceMappings:
        - deviceName: /dev/xvda
          ebs:
            volumeSize: 256Gi
            volumeType: gp3
            encrypted: true
            deleteOnTermination: true
  YAML

  depends_on = [
    module.eks,
    module.eks.eks_managed_node_groups,
    helm_release.karpenter
  ]
}

# Karpenter NodeClass - orchestration
resource "kubectl_manifest" "karpenter_node_class_orchestration" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: orchestration
    spec:
      amiSelectorTerms:
        - alias: al2023@latest

      role: ${module.karpenter.node_iam_role_name}

      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${module.eks.cluster_name}

      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${module.eks.cluster_name}

      tags:
        karpenter.sh/discovery: ${module.eks.cluster_name}

      blockDeviceMappings:
        - deviceName: /dev/xvda
          ebs:
            volumeSize: 256Gi
            volumeType: gp3
            iops: 16000
            throughput: 1000
            encrypted: true
            deleteOnTermination: true

      instanceStorePolicy: RAID0
  YAML

  depends_on = [
    module.eks,
    module.eks.eks_managed_node_groups,
    helm_release.karpenter
  ]
}

# Karpenter NodeClass - GPU (used by burst scaling)
resource "kubectl_manifest" "karpenter_node_class_gpu" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: gpu
    spec:
      amiSelectorTerms:
        - alias: al2023@latest

      role: ${module.karpenter.node_iam_role_name}

      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${module.eks.cluster_name}

      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${module.eks.cluster_name}

      tags:
        karpenter.sh/discovery: ${module.eks.cluster_name}

      blockDeviceMappings:
        - deviceName: /dev/xvda
          ebs:
            volumeSize: 256Gi
            volumeType: gp3
            iops: 16000
            throughput: 1000
            encrypted: true
            deleteOnTermination: true

      instanceStorePolicy: RAID0
  YAML

  depends_on = [
    module.eks,
    module.eks.eks_managed_node_groups,
    helm_release.karpenter
  ]
}

# Karpenter NodeClass - GPU Inference
resource "kubectl_manifest" "karpenter_node_class_gpu_inference" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: gpu-inference
    spec:
      amiSelectorTerms:
        - alias: al2023@latest

      role: ${module.karpenter.node_iam_role_name}

      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${module.eks.cluster_name}

      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${module.eks.cluster_name}

      tags:
        karpenter.sh/discovery: ${module.eks.cluster_name}
        cost-center: llm-inference

      blockDeviceMappings:
        - deviceName: /dev/xvda
          ebs:
            volumeSize: 200Gi
            volumeType: gp3
            iops: 6000
            throughput: 400
            encrypted: true
            deleteOnTermination: true

      instanceStorePolicy: RAID0
  YAML

  depends_on = [
    module.eks,
    module.eks.eks_managed_node_groups,
    helm_release.karpenter
  ]
}

# Karpenter NodeClass - Graviton (ARM64)
resource "kubectl_manifest" "karpenter_node_class_graviton" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: graviton
    spec:
      amiSelectorTerms:
        - alias: al2023@latest

      role: ${module.karpenter.node_iam_role_name}

      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${module.eks.cluster_name}

      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${module.eks.cluster_name}

      tags:
        karpenter.sh/discovery: ${module.eks.cluster_name}

      blockDeviceMappings:
        - deviceName: /dev/xvda
          ebs:
            volumeSize: 256Gi
            volumeType: gp3
            iops: 16000
            throughput: 1000
            encrypted: true
            deleteOnTermination: true

      instanceStorePolicy: RAID0
  YAML

  depends_on = [
    module.eks,
    module.eks.eks_managed_node_groups,
    helm_release.karpenter
  ]
}

# Karpenter NodeClass - Dynamo
resource "kubectl_manifest" "karpenter_node_class_dynamo" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: dynamo
    spec:
      amiSelectorTerms:
        - alias: al2023@latest

      role: ${module.karpenter.node_iam_role_name}

      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${module.eks.cluster_name}

      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${module.eks.cluster_name}

      tags:
        karpenter.sh/discovery: ${module.eks.cluster_name}

      blockDeviceMappings:
        - deviceName: /dev/xvda
          ebs:
            volumeSize: 256Gi
            volumeType: gp3
            iops: 16000
            throughput: 1000
            encrypted: true
            deleteOnTermination: true

      instanceStorePolicy: RAID0
  YAML

  depends_on = [
    module.eks,
    module.eks.eks_managed_node_groups,
    helm_release.karpenter
  ]
}

# Karpenter NodeClass - CPU Optimized
resource "kubectl_manifest" "karpenter_node_class_cpu_optimized" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: cpu-optimized
    spec:
      amiSelectorTerms:
        - alias: al2023@latest

      role: ${module.karpenter.node_iam_role_name}

      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${module.eks.cluster_name}

      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${module.eks.cluster_name}

      tags:
        karpenter.sh/discovery: ${module.eks.cluster_name}

      blockDeviceMappings:
        - deviceName: /dev/xvda
          ebs:
            volumeSize: 256Gi
            volumeType: gp3
            iops: 16000
            throughput: 1000
            encrypted: true
            deleteOnTermination: true

      instanceStorePolicy: RAID0
  YAML

  depends_on = [
    module.eks,
    module.eks.eks_managed_node_groups,
    helm_release.karpenter
  ]
}

# Karpenter NodeClass - Optimized Nodes
resource "kubectl_manifest" "karpenter_node_class_optimized_nodes" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: optimized-nodes
    spec:
      amiSelectorTerms:
        - alias: al2023@latest

      role: ${module.karpenter.node_iam_role_name}

      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${module.eks.cluster_name}

      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${module.eks.cluster_name}

      tags:
        karpenter.sh/discovery: ${module.eks.cluster_name}

      blockDeviceMappings:
        - deviceName: /dev/xvda
          ebs:
            volumeSize: 256Gi
            volumeType: gp3
            iops: 16000
            throughput: 1000
            encrypted: true
            deleteOnTermination: true

      instanceStorePolicy: RAID0
  YAML

  depends_on = [
    module.eks,
    module.eks.eks_managed_node_groups,
    helm_release.karpenter
  ]
}
