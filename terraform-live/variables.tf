# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "llm-vmware-hybrid"
}

variable "region" {
  description = "AWS region for the cluster"
  type        = string
  default     = "ap-northeast-1"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.region))
    error_message = "region deve ser uma região AWS válida (ex: ap-northeast-1)."
  }
}

################################################################################
# On-premises (VMware vSphere) networking
#
# Unlike the upstream sample (which simulates on-premises with a second VPC),
# this VMware flavor connects to a REAL on-premises vSphere environment over a
# Site-to-Site VPN attached to the Transit Gateway. The hybrid node is a VM in
# vCenter, registered via SSM activation + nodeadm.
################################################################################

variable "onprem_node_cidr" {
  description = "On-premises LAN CIDR where the vSphere hybrid node(s) live (RemoteNodeNetwork)"
  type        = string
  default     = "192.168.3.0/24"
}

variable "remote_pod_cidr" {
  description = "CIDR block for pods running on the on-premises hybrid nodes (RemotePodNetwork, reached via Hybrid Nodes Gateway VXLAN)"
  type        = string
  default     = "10.201.0.0/16"
}

variable "customer_gateway_ip" {
  description = "Public IP of the on-premises VPN endpoint (customer gateway). For dynamic residential IPs, update via DDNS automation."
  type        = string
}

variable "customer_gateway_bgp_asn" {
  description = "BGP ASN of the on-premises VPN router (pfSense/edge). Underlay routing is BGP."
  type        = number
  default     = 65000
}

variable "tgw_amazon_side_asn" {
  description = "Amazon-side BGP ASN for the Transit Gateway"
  type        = number
  default     = 64512
}

variable "grafana_admin_password" {
  description = "Grafana admin password — must be set via TF_VAR_grafana_admin_password or terraform.tfvars (never hardcode)"
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.grafana_admin_password) >= 8
    error_message = "grafana_admin_password deve ter pelo menos 8 caracteres."
  }
}

variable "dlc_account_id" {
  description = "AWS Deep Learning Container ECR account ID for your region. See: https://github.com/aws/deep-learning-containers/blob/master/available_images.md"
  type        = string
  default     = "763104351884" # us-east-1, us-west-2, eu-west-1, ap-northeast-1 (most commercial regions)
}
