# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

################################################################################
# EKS Cluster
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.36.0"

  cluster_name    = var.cluster_name
  cluster_version = "1.35"

  cluster_endpoint_public_access = true

  # Service CIDR distinct from the upstream sample to avoid overlap when this
  # cluster shares on-premises transport (Transit Gateway / VPN) with other labs.
  cluster_service_ipv4_cidr = "172.21.0.0/16"

  enable_cluster_creator_admin_permissions = true
  enable_irsa                              = true
  bootstrap_self_managed_addons            = false

  # EKS Addons
  cluster_addons = {
    coredns                   = {}
    kube-proxy                = {}
    eks-node-monitoring-agent = {}
    eks-pod-identity-agent = {
      before_compute = true
    }
    vpc-cni = {
      before_compute = true
      configuration_values = jsonencode({
        env = {
          AWS_VPC_K8S_CNI_EXCLUDE_SNAT_CIDRS = var.remote_pod_cidr
        }
      })
    }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Remote network configuration for hybrid nodes (real on-premises vSphere)
  cluster_remote_network_config = {
    remote_node_networks = {
      cidrs = [var.onprem_node_cidr]
    }
    remote_pod_networks = {
      cidrs = [var.remote_pod_cidr]
    }
  }

  authentication_mode = "API_AND_CONFIG_MAP"

  # Access entries
  access_entries = {
    hybrid_node = {
      principal_arn = aws_iam_role.hybrid_node.arn
      type          = "HYBRID_LINUX"
    }
  }

  # Managed Node Groups
  eks_managed_node_group_defaults = {
    node_repair_config = {
      enabled = true
    }
  }

  eks_managed_node_groups = {
    orchestrating_nodes = {
      instance_types = ["m5.2xlarge"]

      min_size     = 2
      max_size     = 3
      desired_size = 3

      labels = {
        "karpenter.sh/controller" = "true"
        "gpu"                     = "false"
      }

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 256
            volume_type           = "gp3"
            delete_on_termination = true
          }
        }
      }
    }
  }

  tags = merge(local.tags, {
    "karpenter.sh/discovery" = local.name
  })
}
