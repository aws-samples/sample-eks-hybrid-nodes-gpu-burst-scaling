# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

################################################################################
# Application Namespaces
################################################################################

resource "kubectl_manifest" "namespace_models" {
  server_side_apply = true
  yaml_body         = <<-YAML
    apiVersion: v1
    kind: Namespace
    metadata:
      name: models
  YAML

  depends_on = [module.eks]
}

resource "kubectl_manifest" "namespace_dynamo_kubernetes" {
  server_side_apply = true
  yaml_body         = <<-YAML
    apiVersion: v1
    kind: Namespace
    metadata:
      name: dynamo-kubernetes
  YAML

  depends_on = [module.eks]
}

resource "kubectl_manifest" "namespace_orchestration" {
  server_side_apply = true
  yaml_body         = <<-YAML
    apiVersion: v1
    kind: Namespace
    metadata:
      name: orchestration
  YAML

  depends_on = [module.eks]
}
