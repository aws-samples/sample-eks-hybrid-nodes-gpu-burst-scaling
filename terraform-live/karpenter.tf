# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

################################################################################
# Karpenter
################################################################################

# EC2 Spot Service-Linked Role (required for Spot instances)
resource "aws_iam_service_linked_role" "spot" {
  aws_service_name = "spot.amazonaws.com"
  description      = "Service-linked role for EC2 Spot Instances"

  # This role may already exist in the account — ignore if so
  lifecycle {
    ignore_changes = [description]
  }
}

data "aws_ecrpublic_authorization_token" "token" {
  provider = aws.virginia
}

resource "helm_release" "karpenter" {
  namespace           = "karpenter"
  create_namespace    = true
  name                = "karpenter"
  repository          = "oci://public.ecr.aws/karpenter"
  repository_username = data.aws_ecrpublic_authorization_token.token.user_name
  repository_password = data.aws_ecrpublic_authorization_token.token.password
  chart               = "karpenter"
  version             = "1.6.2"
  wait                = true
  timeout             = 300

  values = [
    <<-EOT
    nodeSelector:
      karpenter.sh/controller: 'true'
    dnsPolicy: Default
    settings:
      clusterName: ${module.eks.cluster_name}
      clusterEndpoint: ${module.eks.cluster_endpoint}
      interruptionQueue: ${module.karpenter.queue_name}
      featureGates:
        reservedCapacity: true
    webhook:
      enabled: false
    EOT
  ]

  depends_on = [
    module.karpenter,
    module.eks,
    module.eks.eks_managed_node_groups
  ]
}

################################################################################
# Controller & Node IAM roles, SQS Queue, Eventbridge Rules
################################################################################

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "20.36.0"

  cluster_name          = module.eks.cluster_name
  enable_v1_permissions = true
  namespace             = "karpenter"

  node_iam_role_use_name_prefix   = false
  node_iam_role_name              = local.name
  create_pod_identity_association = true
  create_access_entry             = false # Access entry managed separately to avoid conflict

  # Permissions for capacity reservations
  iam_policy_statements = [
    {
      sid    = "AllowDescribeCapacityReservations"
      effect = "Allow"
      actions = [
        "ec2:DescribeCapacityReservations",
        "ec2:RunInstances",
        "ram:GetResourceShareInvitations",
        "ram:AcceptResourceShareInvitation"
      ]
      resources = ["*"]
    }
  ]

  tags = local.tags
}

################################################################################
# Karpenter Node Access Entry (separate to avoid cycle with EKS module)
################################################################################

resource "aws_eks_access_entry" "karpenter_node" {
  cluster_name  = module.eks.cluster_name
  principal_arn = module.karpenter.node_iam_role_arn
  type          = "EC2_LINUX"
}
