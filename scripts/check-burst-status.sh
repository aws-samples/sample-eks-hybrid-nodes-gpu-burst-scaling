#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# =============================================================================
# check-burst-status.sh — Quick status check of the burst scaling system
#
# Purpose:
#   Displays a dashboard-style overview of the burst scaling components:
#   hybrid and burst deployments, KEDA ScaledObject state, vLLM queue metrics
#   from Prometheus, Karpenter GPU nodes, and all inference pods.
#
# Environment Variables:
#   KUBECONFIG  — Path to kubeconfig (default: kubectl default context)
#
# Prerequisites:
#   - kubectl configured for the EKS cluster
#   - Burst scaling manifests deployed (manifests/burst-scaling/)
#   - Prometheus stack running in the monitoring namespace
#
# Usage:
#   ./scripts/check-burst-status.sh
#   watch -n 10 ./scripts/check-burst-status.sh
# =============================================================================
set -uo pipefail

echo "=== Hybrid Deployment ==="
kubectl get deploy qwen-hybrid -o custom-columns=NAME:.metadata.name,READY:.status.readyReplicas,REPLICAS:.spec.replicas

echo ""
echo "=== Burst Deployment ==="
kubectl get deploy qwen-burst -o custom-columns=NAME:.metadata.name,READY:.status.readyReplicas,REPLICAS:.spec.replicas

echo ""
echo "=== KEDA ScaledObject ==="
kubectl get scaledobject qwen-burst-scaler -o jsonpath='Ready={.status.conditions[?(@.type=="Ready")].status} Active={.status.conditions[?(@.type=="Active")].status}'
echo ""

echo ""
echo "=== vLLM Metrics (from Prometheus) ==="
WAITING=$(kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/query?query=vllm:num_requests_waiting{pod=~"qwen-hybrid.*"}' 2>/dev/null | \
  python3 -c "import sys,json;d=json.load(sys.stdin);r=d['data']['result'];print(r[0]['value'][1] if r else 'N/A')" 2>/dev/null)
RUNNING=$(kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/query?query=vllm:num_requests_running{pod=~"qwen-hybrid.*"}' 2>/dev/null | \
  python3 -c "import sys,json;d=json.load(sys.stdin);r=d['data']['result'];print(r[0]['value'][1] if r else 'N/A')" 2>/dev/null)
echo "  requests_waiting: ${WAITING}"
echo "  requests_running: ${RUNNING}"
if [ "$RUNNING" != "0" ] && [ "$RUNNING" != "N/A" ]; then
  echo "  ratio (waiting/running): $(echo "scale=2; ${WAITING}/${RUNNING}" | bc 2>/dev/null || echo 'N/A')"
fi
echo "  threshold for burst: > 2.0"

echo ""
echo "=== GPU Nodes (Karpenter) ==="
kubectl get nodes -l karpenter.sh/nodepool=gpu -o custom-columns=NAME:.metadata.name,TYPE:.metadata.labels.node\\.kubernetes\\.io/instance-type,AGE:.metadata.creationTimestamp --no-headers 2>/dev/null || echo "  None"

echo ""
echo "=== All Inference Pods ==="
kubectl get pods -l model=qwen25-1-5b -o custom-columns=NAME:.metadata.name,TIER:.metadata.labels.tier,NODE:.spec.nodeName,READY:.status.containerStatuses[0].ready,AGE:.metadata.creationTimestamp
