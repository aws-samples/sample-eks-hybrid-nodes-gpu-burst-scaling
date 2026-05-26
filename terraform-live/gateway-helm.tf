# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

resource "helm_release" "hybrid_nodes_gateway" {
  name             = "eks-hybrid-nodes-gateway"
  repository       = "oci://public.ecr.aws/eks"
  chart            = "eks-hybrid-nodes-gateway"
  version          = "1.0.0"
  namespace        = "eks-hybrid-nodes-gateway"
  create_namespace = true
  wait             = true
  timeout          = 300

  set {
    name  = "vpcCIDR"
    value = local.vpc_cidr
  }

  set {
    name  = "podCIDRs"
    value = var.remote_pod_cidr
  }

  set {
    name  = "routeTableIDs"
    value = join("\\,", module.vpc.private_route_table_ids)
  }

  set {
    name  = "autoMode.enabled"
    value = "false"
  }

  set {
    name  = "nodeSelector.hybrid-gateway-node"
    value = "true"
  }

  set {
    name  = "tolerations[0].key"
    value = "hybrid-gateway-node"
  }

  set {
    name  = "tolerations[0].operator"
    value = "Exists"
  }

  set {
    name  = "tolerations[0].effect"
    value = "NoSchedule"
  }

  depends_on = [
    module.gateway_node_group,
    helm_release.cilium,
    aws_eks_pod_identity_association.gateway,
  ]
}
