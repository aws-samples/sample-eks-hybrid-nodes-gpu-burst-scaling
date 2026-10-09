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
  description = "Transit Gateway ID connecting the EKS VPC to the on-premises side (VPN or nested data center VPC)"
  value       = aws_ec2_transit_gateway.main.id
}

output "ssm_activation_id" {
  description = "SSM activation ID used to register the on-premises hybrid node via nodeadm (vSphere: you pass it to the bootstrap; nested-hyperv: already baked into the VM seed)"
  value       = aws_ssm_activation.hybrid_node.id
}

output "ssm_activation_code" {
  description = "SSM activation code for the on-premises hybrid node (sensitive)"
  value       = aws_ssm_activation.hybrid_node.activation_code
  sensitive   = true
}

output "onprem_mode" {
  description = "On-premises flavor deployed: vsphere or nested-hyperv"
  value       = var.onprem_mode
}

output "nested_hyperv_host_instance_id" {
  description = "nested-hyperv mode: EC2 instance ID of the Hyper-V host (connect with Fleet Manager / Session Manager)"
  value       = local.nested_mode ? aws_cloudformation_stack.nested_host[0].outputs["InstanceId"] : null
}

output "nested_hybrid_node_ip" {
  description = "nested-hyperv mode: IP of the Ubuntu hybrid node VM on the Hyper-V LAN"
  value       = local.nested_mode ? local.nested_vm_ip : null
}

output "nested_setup_status_command" {
  description = "nested-hyperv mode: command that shows the progress of the Hyper-V build (~35-45 min after apply)"
  value = local.nested_mode ? format(
    "aws ssm describe-automation-executions --region %s --filters Key=DocumentNamePrefix,Values=%s --query 'AutomationExecutionMetadataList[0].[AutomationExecutionStatus,CurrentStepName]' --output text",
    var.region, aws_ssm_document.nested_setup[0].name
  ) : null
}

output "configure_kubectl" {
  description = "Command to configure kubectl for the cluster"
  value       = format("aws eks update-kubeconfig --name %s --region %s", module.eks.cluster_name, var.region)
}
