#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# =============================================================================
# observe-scale-down.sh — Observe burst pods scaling back to zero
#
# Purpose:
#   Polls the burst deployment, KEDA ScaledObject, and Karpenter GPU nodes
#   every 30 seconds to observe the scale-down lifecycle after load stops.
#   Exits when burst replicas reach 0 and KEDA becomes inactive, or after
#   ~12 minutes of observation.
#
# Environment Variables:
#   KUBECONFIG  — Path to kubeconfig (default: kubectl default context)
#
# Prerequisites:
#   - kubectl configured for the EKS cluster
#   - Burst scaling manifests deployed (manifests/burst-scaling/)
#   - A prior burst event (run demo-burst-scaling.sh first)
#
# Usage:
#   ./scripts/observe-scale-down.sh
# =============================================================================
set -uo pipefail

COOLDOWN=300
echo "Observing scale-down (cooldown=${COOLDOWN}s)..."
echo "Burst will scale to 0 when queue is empty for ${COOLDOWN}s."
echo ""

for i in $(seq 1 24); do
  BURST=$(kubectl get deploy qwen36-burst -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  BURST=${BURST:-0}
  ACTIVE=$(kubectl get scaledobject qwen36-burst-scaler -o jsonpath='{.status.conditions[?(@.type=="Active")].status}' 2>/dev/null)
  NODES=$(kubectl get nodes -l karpenter.sh/nodepool=gpu --no-headers 2>/dev/null | wc -l | tr -d ' ')
  echo "[$(date +%H:%M:%S)] burst_replicas=${BURST} | KEDA_active=${ACTIVE} | gpu_nodes=${NODES}"
  if [ "$BURST" = "0" ] && [ "$ACTIVE" = "False" ]; then
    echo ""
    echo "✅ Scale-down complete. Burst at 0, KEDA inactive."
    echo "Karpenter will consolidate empty GPU nodes in ~5 min."
    break
  fi
  sleep 30
done
