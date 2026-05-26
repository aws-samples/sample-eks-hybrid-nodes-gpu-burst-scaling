# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "llm-k8sv4"
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

variable "hybrid_vpc_cidr" {
  description = "CIDR block for the hybrid VPC simulating on-premises environment"
  type        = string
  default     = "10.100.0.0/16"
}

variable "hybrid_subnet_cidr" {
  description = "CIDR block for the hybrid private subnet"
  type        = string
  default     = "10.100.0.0/24"
}

variable "remote_pod_cidr" {
  description = "CIDR block for remote pods running on hybrid nodes"
  type        = string
  default     = "10.200.0.0/16"
}

variable "instance_type" {
  description = "EC2 instance type for the hybrid GPU node"
  type        = string
  default     = "g6.12xlarge"
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
