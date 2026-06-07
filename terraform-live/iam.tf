# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

################################################################################
# IAM Roles for Hybrid Nodes
################################################################################

# Hybrid Node IAM Role (SSM trust for hybrid activation)
resource "aws_iam_role" "hybrid_node" {
  name = "${local.name}-hybrid-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ssm.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = local.tags
}

# EKS Worker Node Minimal Policy
resource "aws_iam_policy" "hybrid_node_eks" {
  name        = "${local.name}-hybrid-node-eks"
  description = "Minimal EKS worker node policy for hybrid nodes"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:ListAccessEntries"
        ]
        Resource = "arn:aws:eks:${var.region}:${data.aws_caller_identity.current.account_id}:cluster/${var.cluster_name}"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::vllm-qwen35b-models-${data.aws_caller_identity.current.account_id}",
          "arn:aws:s3:::vllm-qwen35b-models-${data.aws_caller_identity.current.account_id}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "hybrid_node_eks" {
  role       = aws_iam_role.hybrid_node.name
  policy_arn = aws_iam_policy.hybrid_node_eks.arn
}

resource "aws_iam_role_policy_attachment" "hybrid_node_ssm" {
  role       = aws_iam_role.hybrid_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# SSM Activation for hybrid node registration
resource "aws_ssm_activation" "hybrid_node" {
  name               = "${local.name}-hybrid-node"
  iam_role           = aws_iam_role.hybrid_node.id
  registration_limit = 1

  tags = local.tags

  lifecycle {
    ignore_changes = [expiration_date]
  }
}

# NOTE: This VMware flavor does NOT create an EC2 instance profile for the
# hybrid node (the upstream sample did, because its node was EC2 in a simulated
# VPC). Here the node is a VM in vCenter on-premises. It registers with the
# cluster using the SSM activation above (activation id/code) via `nodeadm`.
# See docs/vsphere-onprem-setup.md for the VM provisioning + nodeadm workflow.
