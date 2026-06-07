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

output "transit_gateway_id" {
  description = "Transit Gateway ID connecting the EKS VPC to the on-premises VPN"
  value       = aws_ec2_transit_gateway.main.id
}

output "ssm_activation_id" {
  description = "SSM activation ID used to register the on-premises vSphere hybrid node via nodeadm"
  value       = aws_ssm_activation.hybrid_node.id
}

output "ssm_activation_code" {
  description = "SSM activation code for the on-premises vSphere hybrid node (sensitive)"
  value       = aws_ssm_activation.hybrid_node.activation_code
  sensitive   = true
}

output "configure_kubectl" {
  description = "Command to configure kubectl for the cluster"
  value       = format("aws eks update-kubeconfig --name %s --region %s", module.eks.cluster_name, var.region)
}
