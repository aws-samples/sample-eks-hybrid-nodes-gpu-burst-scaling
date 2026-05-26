# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

output "cluster_endpoint" {
  description = "EKS cluster API endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data for the cluster CA"
  value       = module.eks.cluster_certificate_authority_data
}

output "vpc_id_eks" {
  description = "VPC ID of the EKS cluster"
  value       = module.vpc.vpc_id
}

output "vpc_id_hybrid" {
  description = "VPC ID of the hybrid network"
  value       = aws_vpc.hybrid.id
}

output "transit_gateway_id" {
  description = "Transit Gateway ID connecting EKS and hybrid VPCs"
  value       = aws_ec2_transit_gateway.main.id
}

output "hybrid_node_instance_id" {
  description = "EC2 instance ID of the hybrid GPU node"
  value       = aws_instance.hybrid_gpu_node.id
}

output "configure_kubectl" {
  description = "Command to configure kubectl for the cluster"
  value       = format("aws eks update-kubeconfig --name %s --region %s", module.eks.cluster_name, var.region)
}
