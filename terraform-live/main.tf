# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Configure the AWS provider
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.cluster_name
      Environment = "poc"
      ManagedBy   = "terraform"
    }
  }
}

# Provider for ECR Public token (us-east-1 required)
provider "aws" {
  alias  = "virginia"
  region = "us-east-1"
}

# Configure Kubernetes provider
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

# Configure Helm provider
provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}

# Configure kubectl provider
provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

# Backend local
terraform {
  backend "local" {}
}

# Data sources
data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_region" "current" {}

# Locals
locals {
  name     = var.cluster_name
  vpc_cidr = "10.43.0.0/16"
  azs      = data.aws_availability_zones.available.names

  # EKS pause container image — uses the EKS addon registry for the cluster region.
  # The account 602401143452 is the AWS-managed ECR account for EKS container images
  # in all commercial regions. For GovCloud/China, this would differ.
  # Reference: https://docs.aws.amazon.com/eks/latest/userguide/add-ons-images.html
  eks_pause_image = "602401143452.dkr.ecr.${var.region}.amazonaws.com/eks/pause:3.5"

  tags = {
    Project     = var.cluster_name
    Environment = "poc"
    ManagedBy   = "terraform"
  }
}
