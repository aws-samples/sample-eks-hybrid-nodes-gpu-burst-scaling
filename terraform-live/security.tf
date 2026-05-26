# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

################################################################################
# Security Group for Hybrid Node
################################################################################

resource "aws_security_group" "hybrid_node" {
  name_prefix = "${local.name}-hybrid-node-"
  description = "Security group for hybrid GPU node"
  vpc_id      = aws_vpc.hybrid.id

  tags = merge(local.tags, {
    Name = "${local.name}-hybrid-node-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# Egress: TCP all ports to EKS VPC
resource "aws_security_group_rule" "hybrid_egress_tcp_eks" {
  type              = "egress"
  from_port         = 0
  to_port           = 65535
  protocol          = "tcp"
  cidr_blocks       = [local.vpc_cidr]
  security_group_id = aws_security_group.hybrid_node.id
  description       = "TCP all ports to EKS VPC"
}

# Egress: UDP all ports to EKS VPC
resource "aws_security_group_rule" "hybrid_egress_udp_eks" {
  type              = "egress"
  from_port         = 0
  to_port           = 65535
  protocol          = "udp"
  cidr_blocks       = [local.vpc_cidr]
  security_group_id = aws_security_group.hybrid_node.id
  description       = "UDP all ports to EKS VPC"
}

# Egress: HTTPS to internet (SSM, packages)
resource "aws_security_group_rule" "hybrid_egress_https" {
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.hybrid_node.id
  description       = "HTTPS to internet"
}

# Egress: HTTP to internet
resource "aws_security_group_rule" "hybrid_egress_http" {
  type              = "egress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.hybrid_node.id
  description       = "HTTP to internet"
}

# Egress: DNS to internet
resource "aws_security_group_rule" "hybrid_egress_dns_tcp" {
  type              = "egress"
  from_port         = 53
  to_port           = 53
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.hybrid_node.id
  description       = "DNS TCP to internet"
}

resource "aws_security_group_rule" "hybrid_egress_dns_udp" {
  type              = "egress"
  from_port         = 53
  to_port           = 53
  protocol          = "udp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.hybrid_node.id
  description       = "DNS UDP to internet"
}

# Ingress: Kubelet from EKS VPC
resource "aws_security_group_rule" "hybrid_ingress_kubelet" {
  type              = "ingress"
  from_port         = 10250
  to_port           = 10250
  protocol          = "tcp"
  cidr_blocks       = [local.vpc_cidr]
  security_group_id = aws_security_group.hybrid_node.id
  description       = "Kubelet from EKS VPC"
}

# Ingress: vLLM from EKS VPC
resource "aws_security_group_rule" "hybrid_ingress_vllm" {
  type              = "ingress"
  from_port         = 8000
  to_port           = 8000
  protocol          = "tcp"
  cidr_blocks       = [local.vpc_cidr]
  security_group_id = aws_security_group.hybrid_node.id
  description       = "vLLM from EKS VPC"
}

# Ingress: Cilium VXLAN from EKS VPC
resource "aws_security_group_rule" "hybrid_ingress_cilium_vxlan" {
  type              = "ingress"
  from_port         = 8472
  to_port           = 8472
  protocol          = "udp"
  cidr_blocks       = [local.vpc_cidr]
  security_group_id = aws_security_group.hybrid_node.id
  description       = "Cilium VXLAN from EKS VPC"
}

# Ingress: Cilium health from EKS VPC
resource "aws_security_group_rule" "hybrid_ingress_cilium_health" {
  type              = "ingress"
  from_port         = 4240
  to_port           = 4240
  protocol          = "tcp"
  cidr_blocks       = [local.vpc_cidr]
  security_group_id = aws_security_group.hybrid_node.id
  description       = "Cilium health from EKS VPC"
}

# Ingress: TCP all ports from EKS VPC
resource "aws_security_group_rule" "hybrid_ingress_tcp_all" {
  type              = "ingress"
  from_port         = 0
  to_port           = 65535
  protocol          = "tcp"
  cidr_blocks       = [local.vpc_cidr]
  security_group_id = aws_security_group.hybrid_node.id
  description       = "TCP all ports from EKS VPC"
}

################################################################################
# Additional rules on EKS cluster security groups
################################################################################

# Ingress: HTTPS from hybrid subnet to cluster SG (API server access)
resource "aws_security_group_rule" "eks_cluster_ingress_hybrid_https" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = [var.hybrid_subnet_cidr]
  security_group_id = module.eks.cluster_security_group_id
  description       = "HTTPS from hybrid nodes"
}

# Ingress: HTTPS from remote pods to cluster SG
resource "aws_security_group_rule" "eks_cluster_ingress_pods_https" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = [var.remote_pod_cidr]
  security_group_id = module.eks.cluster_security_group_id
  description       = "HTTPS from remote pods"
}

# Ingress: Cilium VXLAN from hybrid subnet to node SG
resource "aws_security_group_rule" "eks_node_ingress_cilium_vxlan" {
  type              = "ingress"
  from_port         = 8472
  to_port           = 8472
  protocol          = "udp"
  cidr_blocks       = [var.hybrid_subnet_cidr]
  security_group_id = module.eks.node_security_group_id
  description       = "Cilium VXLAN from hybrid nodes"
}

# Ingress: Cilium health from hybrid subnet to node SG
resource "aws_security_group_rule" "eks_node_ingress_cilium_health" {
  type              = "ingress"
  from_port         = 4240
  to_port           = 4240
  protocol          = "tcp"
  cidr_blocks       = [var.hybrid_subnet_cidr]
  security_group_id = module.eks.node_security_group_id
  description       = "Cilium health from hybrid nodes"
}

# Ingress: TCP all ports from hybrid subnet to node SG
resource "aws_security_group_rule" "eks_node_ingress_hybrid_tcp" {
  type              = "ingress"
  from_port         = 0
  to_port           = 65535
  protocol          = "tcp"
  cidr_blocks       = [var.hybrid_subnet_cidr]
  security_group_id = module.eks.node_security_group_id
  description       = "TCP all from hybrid nodes"
}

# Ingress: UDP all ports from hybrid subnet to node SG
resource "aws_security_group_rule" "eks_node_ingress_hybrid_udp" {
  type              = "ingress"
  from_port         = 0
  to_port           = 65535
  protocol          = "udp"
  cidr_blocks       = [var.hybrid_subnet_cidr]
  security_group_id = module.eks.node_security_group_id
  description       = "UDP all from hybrid nodes"
}

# Ingress: TCP all ports from remote pods to node SG
resource "aws_security_group_rule" "eks_node_ingress_pods_tcp" {
  type              = "ingress"
  from_port         = 0
  to_port           = 65535
  protocol          = "tcp"
  cidr_blocks       = [var.remote_pod_cidr]
  security_group_id = module.eks.node_security_group_id
  description       = "TCP all from remote pods"
}

# Ingress: UDP all ports from remote pods to node SG
resource "aws_security_group_rule" "eks_node_ingress_pods_udp" {
  type              = "ingress"
  from_port         = 0
  to_port           = 65535
  protocol          = "udp"
  cidr_blocks       = [var.remote_pod_cidr]
  security_group_id = module.eks.node_security_group_id
  description       = "UDP all from remote pods"
}
