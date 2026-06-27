# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

################################################################################
# Render Kubernetes Manifests from Templates
#
# Replaces placeholders in manifest templates with actual values from Terraform
# variables and resources. Rendered manifests are written to:
#   manifests/burst-scaling/rendered/
#
# After 'terraform apply', deploy with:
#   kubectl apply -f manifests/burst-scaling/rendered/
################################################################################

locals {
  manifest_template_vars = {
    dlc_account_id = var.dlc_account_id
    region         = var.region
  }

  manifests_dir = "${path.module}/../manifests/burst-scaling"
  rendered_dir  = "${path.module}/../manifests/burst-scaling/rendered"
}

resource "local_file" "hybrid_deployment" {
  content  = templatefile("${local.manifests_dir}/02-hybrid-deployment.yaml.tpl", local.manifest_template_vars)
  filename = "${local.rendered_dir}/02-hybrid-deployment.yaml"

  file_permission = "0644"
}

resource "local_file" "burst_deployment" {
  content  = templatefile("${local.manifests_dir}/03-burst-deployment.yaml.tpl", local.manifest_template_vars)
  filename = "${local.rendered_dir}/03-burst-deployment.yaml"

  file_permission = "0644"
}

# Copy static manifests (no placeholders) to rendered/ for convenience
# so users can 'kubectl apply -f rendered/' for everything
resource "local_file" "static_manifests" {
  for_each = toset([
    "01-service.yaml",
    "04-keda-scaledobject.yaml",
    "05-servicemonitor.yaml",
    "06-prometheusrule.yaml",
    "07-networkpolicy.yaml",
    "08-pdb.yaml",
    "09-grafana-dashboard.yaml",
    "11-dcgm-servicemonitor.yaml",
    "12-gateway-servicemonitor.yaml",
    "13-gateway-alerts.yaml",
    "14-cilium-networkpolicy.yaml",
  ])

  content  = file("${local.manifests_dir}/${each.value}")
  filename = "${local.rendered_dir}/${each.value}"

  file_permission = "0644"
}
