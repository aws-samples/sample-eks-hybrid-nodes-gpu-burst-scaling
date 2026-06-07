# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

################################################################################
# Security rules on the EKS cluster/node security groups for hybrid traffic
#
# In this VMware flavor the on-premises hybrid node lives in a real vSphere
# environment behind the customer edge firewall (e.g. pfSense), reached over a
# Site-to-Site VPN. There is no AWS security group on the node itself (unlike
# the upstream sample where the node was an EC2 instance in a simulated VPC).
# Inbound filtering on the node is the customer's responsibility on-premises.
#
# What remains here are the rules on the EKS-side security groups that allow
# traffic coming FROM the on-premises node/pod CIDRs (over the VPN/TGW).
################################################################################

# Ingress: HTTPS from on-premises node LAN to cluster SG (API server access)
resource "aws_security_group_rule" "eks_cluster_ingress_hybrid_https" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = [var.onprem_node_cidr]
  security_group_id = module.eks.cluster_security_group_id
  description       = "HTTPS from on-premises hybrid nodes"
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

# Ingress: Cilium VXLAN from on-premises node LAN to node SG
resource "aws_security_group_rule" "eks_node_ingress_cilium_vxlan" {
  type              = "ingress"
  from_port         = 8472
  to_port           = 8472
  protocol          = "udp"
  cidr_blocks       = [var.onprem_node_cidr]
  security_group_id = module.eks.node_security_group_id
  description       = "Cilium VXLAN from on-premises hybrid nodes"
}

# Ingress: Cilium health from on-premises node LAN to node SG
resource "aws_security_group_rule" "eks_node_ingress_cilium_health" {
  type              = "ingress"
  from_port         = 4240
  to_port           = 4240
  protocol          = "tcp"
  cidr_blocks       = [var.onprem_node_cidr]
  security_group_id = module.eks.node_security_group_id
  description       = "Cilium health from on-premises hybrid nodes"
}

# Ingress: TCP all ports from on-premises node LAN to node SG
resource "aws_security_group_rule" "eks_node_ingress_hybrid_tcp" {
  type              = "ingress"
  from_port         = 0
  to_port           = 65535
  protocol          = "tcp"
  cidr_blocks       = [var.onprem_node_cidr]
  security_group_id = module.eks.node_security_group_id
  description       = "TCP all from on-premises hybrid nodes"
}

# Ingress: UDP all ports from on-premises node LAN to node SG
resource "aws_security_group_rule" "eks_node_ingress_hybrid_udp" {
  type              = "ingress"
  from_port         = 0
  to_port           = 65535
  protocol          = "udp"
  cidr_blocks       = [var.onprem_node_cidr]
  security_group_id = module.eks.node_security_group_id
  description       = "UDP all from on-premises hybrid nodes"
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
