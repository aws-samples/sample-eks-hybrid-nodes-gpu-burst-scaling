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

variable "onprem_mode" {
  description = <<-EOT
    Where the on-premises hybrid node runs:
      - "vsphere"       : a VM in YOUR VMware vSphere, reached over Site-to-Site VPN (default)
      - "nested-hyperv" : a Hyper-V VM on an EC2 host with nested virtualization, built by
                          this Terraform. A real hypervisor for demos/PoCs without vSphere hardware.
  EOT
  type        = string
  default     = "vsphere"

  validation {
    condition     = contains(["vsphere", "nested-hyperv"], var.onprem_mode)
    error_message = "onprem_mode must be \"vsphere\" or \"nested-hyperv\"."
  }
}

variable "onprem_node_cidr" {
  description = "On-premises LAN CIDR where the hybrid node(s) live (RemoteNodeNetwork). In nested-hyperv mode this is the Hyper-V internal switch network."
  type        = string
  default     = "192.168.3.0/24"
}

variable "remote_pod_cidr" {
  description = "CIDR block for pods running on the on-premises hybrid nodes (RemotePodNetwork, reached via Hybrid Nodes Gateway VXLAN)"
  type        = string
  default     = "10.201.0.0/16"
}

variable "customer_gateway_ip" {
  description = "Public IP of the on-premises VPN endpoint (customer gateway). Required when onprem_mode = \"vsphere\". For dynamic residential IPs, update via DDNS automation."
  type        = string
  default     = null
}

################################################################################
# Nested Hyper-V on-premises (onprem_mode = "nested-hyperv")
#
# Ported from the EKS Hybrid Nodes workshop: an EC2 8th-gen Intel instance with
# nested virtualization runs Windows Server + Hyper-V, and an Ubuntu guest VM on
# it is the hybrid node. Only used in nested-hyperv mode.
################################################################################

variable "nested_dc_vpc_cidr" {
  description = "CIDR of the VPC that plays the data center (holds the Hyper-V host). Must not overlap the EKS VPC (10.43.0.0/16), onprem_node_cidr or remote_pod_cidr."
  type        = string
  default     = "10.90.0.0/16"
}

variable "nested_host_instance_type" {
  description = "Hyper-V host instance type. Nested virtualization requires 8th-gen Intel (C8i, M8i, R8i and their flex variants)."
  type        = string
  default     = "m8i.2xlarge"

  validation {
    condition     = can(regex("^(c8i|m8i|r8i)(-flex)?\\.", var.nested_host_instance_type))
    error_message = "Nested virtualization is only supported on C8i, M8i and R8i (and -flex) instance types."
  }
}

variable "nested_vm_vcpus" {
  description = "vCPUs of the Ubuntu hybrid node VM inside Hyper-V (leave ~2 vCPUs to the Windows host)"
  type        = number
  default     = 6
}

variable "nested_vm_memory_gb" {
  description = "Memory (GB, static) of the Ubuntu hybrid node VM inside Hyper-V"
  type        = number
  default     = 16
}

variable "nested_vm_disk_gb" {
  description = "Disk size (GB) of the Ubuntu hybrid node VM (OS + container images + model cache)"
  type        = number
  default     = 80
}

variable "nested_ubuntu_image_url" {
  description = "Ubuntu cloud image (qcow2) converted to VHDX for the Hyper-V VM"
  type        = string
  default     = "https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-amd64.img"
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
