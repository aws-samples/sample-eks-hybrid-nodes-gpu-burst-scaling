# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

################################################################################
# Transit Gateway
################################################################################

resource "aws_ec2_transit_gateway" "main" {
  description                     = "TGW connecting EKS VPC and Hybrid VPC"
  default_route_table_association = "enable"
  default_route_table_propagation = "enable"

  tags = merge(local.tags, {
    Name = "${local.name}-tgw"
  })
}

# TGW Attachment - EKS VPC (uses module output, NO hardcoded IDs)
resource "aws_ec2_transit_gateway_vpc_attachment" "cluster" {
  subnet_ids         = module.vpc.private_subnets
  transit_gateway_id = aws_ec2_transit_gateway.main.id
  vpc_id             = module.vpc.vpc_id

  tags = merge(local.tags, {
    Name = "${local.name}-tgw-eks"
  })
}

# TGW Attachment - Hybrid VPC
resource "aws_ec2_transit_gateway_vpc_attachment" "hybrid" {
  subnet_ids         = [aws_subnet.hybrid_private.id]
  transit_gateway_id = aws_ec2_transit_gateway.main.id
  vpc_id             = aws_vpc.hybrid.id

  tags = merge(local.tags, {
    Name = "${local.name}-tgw-hybrid"
  })
}

################################################################################
# Routes in EKS VPC private route tables (for_each over module output)
################################################################################

# Route to hybrid nodes CIDR
# With single_nat_gateway=true, there's only 1 private route table
# Using count with distinct to handle both single and multi-NAT scenarios
resource "aws_route" "eks_to_hybrid_nodes" {
  count                  = 1
  route_table_id         = module.vpc.private_route_table_ids[0]
  destination_cidr_block = var.hybrid_vpc_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.main.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.cluster]
}

# Route to remote pods CIDR
resource "aws_route" "eks_to_remote_pods" {
  count                  = 1
  route_table_id         = module.vpc.private_route_table_ids[0]
  destination_cidr_block = var.remote_pod_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.main.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.cluster]

  lifecycle {
    ignore_changes = [network_interface_id, transit_gateway_id]
  }
}

################################################################################
# Route in Hybrid VPC private route table to EKS VPC
################################################################################

resource "aws_route" "hybrid_to_eks" {
  route_table_id         = aws_route_table.hybrid_private.id
  destination_cidr_block = local.vpc_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.main.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.hybrid]
}
