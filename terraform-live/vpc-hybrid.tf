# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

################################################################################
# Hybrid VPC (simulates on-premises environment)
################################################################################

resource "aws_vpc" "hybrid" {
  cidr_block           = var.hybrid_vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.tags, {
    Name = "${local.name}-hybrid-vpc"
  })
}

# Private subnet for hybrid nodes
resource "aws_subnet" "hybrid_private" {
  vpc_id            = aws_vpc.hybrid.id
  cidr_block        = var.hybrid_subnet_cidr
  availability_zone = local.azs[0]

  tags = merge(local.tags, {
    Name = "${local.name}-hybrid-private"
  })
}

# Public subnet for NAT Gateway
resource "aws_subnet" "hybrid_public" {
  vpc_id                  = aws_vpc.hybrid.id
  cidr_block              = "10.100.100.0/24"
  availability_zone       = local.azs[0]
  map_public_ip_on_launch = true

  tags = merge(local.tags, {
    Name = "${local.name}-hybrid-public"
  })
}

# Internet Gateway
resource "aws_internet_gateway" "hybrid" {
  vpc_id = aws_vpc.hybrid.id

  tags = merge(local.tags, {
    Name = "${local.name}-hybrid-igw"
  })
}

# NAT Gateway EIP
resource "aws_eip" "hybrid_nat" {
  domain = "vpc"

  tags = merge(local.tags, {
    Name = "${local.name}-hybrid-nat-eip"
  })

  depends_on = [aws_internet_gateway.hybrid]
}

# NAT Gateway
resource "aws_nat_gateway" "hybrid" {
  allocation_id = aws_eip.hybrid_nat.id
  subnet_id     = aws_subnet.hybrid_public.id

  tags = merge(local.tags, {
    Name = "${local.name}-hybrid-nat"
  })

  depends_on = [aws_internet_gateway.hybrid]
}

# Public route table
resource "aws_route_table" "hybrid_public" {
  vpc_id = aws_vpc.hybrid.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.hybrid.id
  }

  tags = merge(local.tags, {
    Name = "${local.name}-hybrid-public-rt"
  })
}

resource "aws_route_table_association" "hybrid_public" {
  subnet_id      = aws_subnet.hybrid_public.id
  route_table_id = aws_route_table.hybrid_public.id
}

# Private route table
resource "aws_route_table" "hybrid_private" {
  vpc_id = aws_vpc.hybrid.id

  tags = merge(local.tags, {
    Name = "${local.name}-hybrid-private-rt"
  })

  # Routes managed via separate aws_route resources (tgw.tf)
  # to avoid conflicts with inline route blocks
  lifecycle {
    ignore_changes = [route]
  }
}

resource "aws_route_table_association" "hybrid_private" {
  subnet_id      = aws_subnet.hybrid_private.id
  route_table_id = aws_route_table.hybrid_private.id
}

# Default route to internet via NAT Gateway
resource "aws_route" "hybrid_private_default" {
  route_table_id         = aws_route_table.hybrid_private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.hybrid.id
}

################################################################################
# CKV2_AWS_12: Restrict default security group to deny all traffic
################################################################################

resource "aws_default_security_group" "hybrid" {
  vpc_id = aws_vpc.hybrid.id
  # No ingress/egress rules = deny all traffic

  tags = merge(local.tags, {
    Name = "${local.name}-default-do-not-use"
  })
}
