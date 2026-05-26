# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

################################################################################
# Knative Serving (via kubectl_manifest — NO official Helm chart)
################################################################################

# Knative Operator namespace
resource "kubectl_manifest" "knative_operator_namespace" {
  yaml_body = <<-YAML
    apiVersion: v1
    kind: Namespace
    metadata:
      name: knative-operator
  YAML

  depends_on = [module.eks.eks_managed_node_groups]
}

# Knative Serving namespace
resource "kubectl_manifest" "knative_serving_namespace" {
  yaml_body = <<-YAML
    apiVersion: v1
    kind: Namespace
    metadata:
      name: knative-serving
  YAML

  depends_on = [module.eks.eks_managed_node_groups]
}

# Kourier namespace
resource "kubectl_manifest" "kourier_namespace" {
  yaml_body = <<-YAML
    apiVersion: v1
    kind: Namespace
    metadata:
      name: kourier-system
  YAML

  depends_on = [module.eks.eks_managed_node_groups]
}

# Install Knative Operator from official release YAML
data "http" "knative_operator_yaml" {
  url = "https://github.com/knative/operator/releases/download/knative-v1.18.2/operator.yaml"
}

data "kubectl_file_documents" "knative_operator" {
  content = data.http.knative_operator_yaml.response_body
}

resource "kubectl_manifest" "knative_operator" {
  for_each  = data.kubectl_file_documents.knative_operator.manifests
  yaml_body = each.value

  depends_on = [
    module.eks.eks_managed_node_groups,
    kubectl_manifest.knative_operator_namespace
  ]
}

# KnativeServing CR with Kourier networking
resource "kubectl_manifest" "knative_serving" {
  yaml_body = <<-YAML
    apiVersion: operator.knative.dev/v1beta1
    kind: KnativeServing
    metadata:
      name: knative-serving
      namespace: knative-serving
    spec:
      version: "1.18.2"
      ingress:
        kourier:
          enabled: true
      config:
        network:
          ingress-class: kourier.ingress.networking.knative.dev
  YAML

  depends_on = [
    kubectl_manifest.knative_operator,
    kubectl_manifest.knative_serving_namespace
  ]
}
