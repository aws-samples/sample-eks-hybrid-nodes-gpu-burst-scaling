# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

module "gateway_node_group" {
  source  = "terraform-aws-modules/eks/aws//modules/eks-managed-node-group"
  version = "20.36.0"

  name                 = "gateway-nodes"
  cluster_name         = module.eks.cluster_name
  cluster_version      = module.eks.cluster_version
  cluster_service_cidr = module.eks.cluster_service_cidr
  subnet_ids           = [module.vpc.private_subnets[0], module.vpc.private_subnets[2]]

  cluster_primary_security_group_id = module.eks.cluster_primary_security_group_id
  vpc_security_group_ids            = [module.eks.node_security_group_id]

  instance_types = ["m5.large"]
  min_size       = 2
  max_size       = 2
  desired_size   = 2

  labels = {
    "hybrid-gateway-node" = "true"
  }

  taints = {
    gateway = {
      key    = "hybrid-gateway-node"
      effect = "NO_SCHEDULE"
    }
  }

  create_launch_template = true
  launch_template_name   = "${local.name}-gateway"

  pre_bootstrap_user_data = <<-EOT
    #!/bin/bash
    TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
    MAC=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/mac)
    ENI_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/network/interfaces/macs/$${MAC}/interface-id")
    REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)
    aws ec2 modify-network-interface-attribute --network-interface-id "$ENI_ID" --no-source-dest-check --region "$REGION"
  EOT

  iam_role_additional_policies = {
    gateway_src_dst = aws_iam_policy.gateway_route_management.arn
  }

  tags = local.tags
}
