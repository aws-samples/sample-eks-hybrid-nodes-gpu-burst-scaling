# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

resource "aws_iam_policy" "gateway_route_management" {
  name = "${local.name}-gateway-route-mgmt"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DescribeResources"
        Effect = "Allow"
        Action = [
          "ec2:DescribeRouteTables",
          "ec2:DescribeInstances"
        ]
        Resource = "*"
      },
      {
        Sid    = "ManageRoutes"
        Effect = "Allow"
        Action = [
          "ec2:CreateRoute",
          "ec2:ReplaceRoute",
          "ec2:DeleteRoute"
        ]
        Resource = [for rt_id in module.vpc.private_route_table_ids :
          "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:route-table/${rt_id}"
        ]
      }
    ]
  })
}

resource "aws_iam_role" "gateway_pod_identity" {
  name = "${local.name}-gateway-pod-identity"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "gateway_pod_identity" {
  role       = aws_iam_role.gateway_pod_identity.name
  policy_arn = aws_iam_policy.gateway_route_management.arn
}

resource "aws_eks_pod_identity_association" "gateway" {
  cluster_name    = module.eks.cluster_name
  namespace       = "eks-hybrid-nodes-gateway"
  service_account = "eks-hybrid-nodes-gateway"
  role_arn        = aws_iam_role.gateway_pod_identity.arn
}
