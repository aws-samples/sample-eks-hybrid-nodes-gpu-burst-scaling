# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

################################################################################
# Observability Stack (Kube Prometheus Stack + Grafana Operator)
################################################################################

resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "69.7.4"
  namespace        = "monitoring"
  create_namespace = true
  wait             = true
  timeout          = 600

  values = [
    <<-EOT
    grafana:
      enabled: true
      defaultDashboardsEnabled: true
      adminPassword: "${var.grafana_admin_password}"
      nodeSelector:
        karpenter.sh/controller: "true"
      service:
        type: ClusterIP
        port: 3000
    prometheus:
      prometheusSpec:
        serviceMonitorSelectorNilUsesHelmValues: false
        nodeSelector:
          karpenter.sh/controller: "true"
    alertmanager:
      alertmanagerSpec:
        nodeSelector:
          karpenter.sh/controller: "true"
    kube-state-metrics:
      nodeSelector:
        karpenter.sh/controller: "true"
    prometheus-node-exporter:
      tolerations:
        - operator: Exists
    prometheusOperator:
      nodeSelector:
        karpenter.sh/controller: "true"
    EOT
  ]

  depends_on = [
    module.eks,
    module.eks.eks_managed_node_groups,
    helm_release.aws_load_balancer_controller
  ]
}

resource "helm_release" "grafana_operator" {
  name       = "grafana-operator"
  namespace  = "monitoring"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "grafana-operator"
  version    = "5.16.0"
  wait       = true
  timeout    = 300

  values = [
    <<-EOT
    operator:
      scanAllNamespaces: true
    nodeSelector:
      karpenter.sh/controller: "true"
    EOT
  ]

  depends_on = [
    module.eks,
    module.eks.eks_managed_node_groups,
    helm_release.kube_prometheus_stack
  ]
}
