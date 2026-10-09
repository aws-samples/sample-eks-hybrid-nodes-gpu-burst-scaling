# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

################################################################################
# Transit Gateway + Site-to-Site VPN to on-premises vSphere
#
# Unlike the upstream sample (TGW attachment to a simulated hybrid VPC), this
# VMware flavor connects the EKS VPC to a REAL on-premises environment over a
# Site-to-Site VPN. The customer edge (e.g. pfSense) terminates the VPN and
# routes to the vSphere hybrid node LAN and the remote pod CIDR.
#
# Underlay routing is BGP (dynamic). The Hybrid Nodes Gateway VXLAN overlay
# runs on top of this transport, transparent to the underlay routing choice.
################################################################################

resource "aws_ec2_transit_gateway" "main" {
  description                     = local.vsphere_mode ? "TGW connecting EKS VPC and on-premises vSphere via VPN" : "TGW connecting EKS VPC and the nested Hyper-V data center VPC"
  amazon_side_asn                 = var.tgw_amazon_side_asn
  default_route_table_association = "enable"
  default_route_table_propagation = "enable"

  tags = merge(local.tags, {
    Name = "${local.name}-tgw"
  })
}

# TGW Attachment - EKS VPC
resource "aws_ec2_transit_gateway_vpc_attachment" "cluster" {
  subnet_ids         = module.vpc.private_subnets
  transit_gateway_id = aws_ec2_transit_gateway.main.id
  vpc_id             = module.vpc.vpc_id

  tags = merge(local.tags, {
    Name = "${local.name}-tgw-eks"
  })
}

################################################################################
# Customer Gateway + VPN Connection (to on-premises edge router)
# vsphere mode only. In nested-hyperv mode the data center is a VPC attached to
# this same TGW (see onprem-nested-hyperv.tf), so there is no customer edge.
################################################################################

resource "aws_customer_gateway" "onprem" {
  count = local.vsphere_mode ? 1 : 0

  bgp_asn    = var.customer_gateway_bgp_asn
  ip_address = var.customer_gateway_ip
  type       = "ipsec.1"

  tags = merge(local.tags, {
    Name = "${local.name}-onprem-cgw"
  })

  lifecycle {
    precondition {
      condition     = var.customer_gateway_ip != null
      error_message = "customer_gateway_ip is required when onprem_mode = \"vsphere\"."
    }
  }
}

resource "aws_vpn_connection" "onprem" {
  count = local.vsphere_mode ? 1 : 0

  customer_gateway_id = aws_customer_gateway.onprem[0].id
  transit_gateway_id  = aws_ec2_transit_gateway.main.id
  type                = "ipsec.1"
  static_routes_only  = false # BGP (dynamic)

  tags = merge(local.tags, {
    Name = "${local.name}-onprem-vpn"
  })
}

################################################################################
# Routes in EKS VPC private route tables toward on-premises (via TGW)
################################################################################

# Route to on-premises hybrid node LAN
resource "aws_route" "eks_to_onprem_nodes" {
  route_table_id         = module.vpc.private_route_table_ids[0]
  destination_cidr_block = var.onprem_node_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.main.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.cluster]
}

# Route to remote pods CIDR.
# NOTE: with the Hybrid Nodes Gateway, pod traffic is VXLAN-encapsulated and
# the VPC route table entry for the pod CIDR points to the Gateway leader ENI
# (managed by the gateway controller), NOT to the TGW. This baseline route via
# TGW is created for initial reachability; the gateway controller updates the
# pod CIDR route to its leader ENI at runtime.
resource "aws_route" "eks_to_remote_pods" {
  route_table_id         = module.vpc.private_route_table_ids[0]
  destination_cidr_block = var.remote_pod_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.main.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.cluster]

  lifecycle {
    ignore_changes = [network_interface_id, transit_gateway_id]
  }
}
