#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# =============================================================================
# demo-burst-scaling.sh — Demonstrate hybrid-to-cloud burst scaling
#
# Purpose:
#   Drives a sustained load against the hybrid vLLM pod to saturate its request
#   queue, triggering KEDA to scale the burst deployment from 0 to 1+. Monitors
#   Prometheus metrics, Karpenter node provisioning, and burst pod readiness.
#   Shows the full burst-scaling lifecycle end-to-end.
#
# Environment Variables:
#   HYBRID_IP   — ClusterIP or host IP of the hybrid vLLM pod (auto-detected)
#   VLLM_PORT   — vLLM serving port (default: 8000)
#   CONCURRENT  — Total number of requests to send (default: 500)
#   ROUNDS      — Number of load rounds (default: 5)
#   BATCH       — Requests per round (default: 100)
#
# Prerequisites:
#   - kubectl configured for the EKS cluster
#   - Burst scaling manifests deployed (manifests/burst-scaling/)
#   - Prometheus stack running in the monitoring namespace
#
# Usage:
#   ./scripts/demo-burst-scaling.sh
#   HYBRID_IP=10.100.0.50 ./scripts/demo-burst-scaling.sh
#   ROUNDS=10 BATCH=200 ./scripts/demo-burst-scaling.sh
# =============================================================================
set -uo pipefail

HYBRID_IP="${HYBRID_IP:-$(kubectl get svc qwen-burst-svc -o jsonpath='{.spec.clusterIP}' 2>/dev/null || kubectl get pod -l tier=hybrid -o jsonpath='{.items[0].status.hostIP}' 2>/dev/null || echo 10.100.0.137)}"
VLLM_PORT="${VLLM_PORT:-8000}"
CONCURRENT="${CONCURRENT:-500}"
ROUNDS="${ROUNDS:-5}"
BATCH="${BATCH:-100}"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Hybrid-to-Cloud Burst Scaling Demo                         ║"
echo "║  Target: ${HYBRID_IP}:${VLLM_PORT}                         ║"
echo "║  Load: ${CONCURRENT} requests (${ROUNDS} rounds × ${BATCH})║"
echo "╚══════════════════════════════════════════════════════════════╝"

echo ""
echo "=== BEFORE: Baseline state ==="
kubectl get deploy qwen-hybrid qwen-burst
kubectl get scaledobject qwen-burst-scaler -o jsonpath='KEDA Active: {.status.conditions[?(@.type=="Active")].status}'
echo ""
kubectl get nodeclaims 2>/dev/null | grep gpu || echo "No GPU nodeclaims"
echo ""

echo "=== Step 1: Generating sustained load via in-cluster Job ==="
kubectl delete job burst-demo-load --ignore-not-found 2>/dev/null
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: burst-demo-load
spec:
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: load
          image: curlimages/curl
          command: ["/bin/sh", "-c"]
          args:
            - |
              for round in \$(seq 1 ${ROUNDS}); do
                echo "Round \$round: sending ${BATCH} requests..."
                for i in \$(seq 1 ${BATCH}); do
                  curl -s http://${HYBRID_IP}:${VLLM_PORT}/v1/chat/completions \
                    -H "Content-Type: application/json" \
                    -d '{"model":"Qwen2.5-1.5B-Instruct","messages":[{"role":"user","content":"Write an extremely detailed and comprehensive essay about the complete history of artificial intelligence"}],"max_tokens":1024}' &
                done
                sleep 5
              done
              wait
EOF
echo "Load job submitted."
echo ""

echo "=== Step 2: Monitoring metrics (polling every 15s) ==="
for i in $(seq 1 8); do
  sleep 15
  WAITING=$(kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \
    wget -qO- 'http://localhost:9090/api/v1/query?query=vllm:num_requests_waiting{pod=~"qwen-hybrid.*"}' 2>/dev/null | \
    python3 -c "import sys,json;d=json.load(sys.stdin);r=d['data']['result'];print(r[0]['value'][1] if r else '0')" 2>/dev/null)
  RUNNING=$(kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \
    wget -qO- 'http://localhost:9090/api/v1/query?query=vllm:num_requests_running{pod=~"qwen-hybrid.*"}' 2>/dev/null | \
    python3 -c "import sys,json;d=json.load(sys.stdin);r=d['data']['result'];print(r[0]['value'][1] if r else '0')" 2>/dev/null)
  ACTIVE=$(kubectl get scaledobject qwen-burst-scaler -o jsonpath='{.status.conditions[?(@.type=="Active")].status}' 2>/dev/null)
  BURST_REPLICAS=$(kubectl get deploy qwen-burst -o jsonpath='{.spec.replicas}' 2>/dev/null)
  echo "  [${i}] waiting=${WAITING} running=${RUNNING} | KEDA Active=${ACTIVE} | burst replicas=${BURST_REPLICAS}"
  if [ "$ACTIVE" = "True" ]; then
    echo "  >>> KEDA TRIGGERED! Burst scaling activated."
    break
  fi
done
echo ""

echo "=== Step 3: Observing Karpenter provisioning ==="
sleep 10
echo "Burst pods:"
kubectl get pods -l tier=burst -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName
echo ""
echo "GPU NodeClaims:"
kubectl get nodeclaims -o custom-columns=NAME:.metadata.name,TYPE:.status.instanceType,CAPACITY:.status.capacity.karpenter\\.sh/capacity-type,STATE:.status.conditions[-1:].type 2>/dev/null | grep gpu
echo ""

echo "=== Step 4: Waiting for burst pods to be Ready (up to 5 min) ==="
kubectl wait --for=condition=Ready pod -l tier=burst --timeout=300s 2>&1 || echo "Some burst pods may still be initializing"
echo ""

echo "=== AFTER: Final state ==="
kubectl get deploy qwen-hybrid qwen-burst
echo ""
echo "All inference pods:"
kubectl get pods -l model=qwen25-1-5b -o custom-columns=NAME:.metadata.name,TIER:.metadata.labels.tier,NODE:.spec.nodeName,READY:.status.containerStatuses[0].ready
echo ""
echo "GPU nodes provisioned by Karpenter:"
kubectl get nodes -l karpenter.sh/nodepool=gpu -o custom-columns=NAME:.metadata.name,TYPE:.metadata.labels.node\\.kubernetes\\.io/instance-type,CAPACITY:.metadata.labels.karpenter\\.sh/capacity-type
echo ""
echo "Service endpoints (hybrid + burst):"
kubectl get endpoints qwen-burst-svc -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null
echo ""
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Demo complete. Burst scaling triggered successfully.       ║"
echo "║  To observe scale-down, wait 5 min (cooldown=300s).        ║"
echo "║  Run: watch kubectl get deploy qwen-burst                 ║"
echo "╚══════════════════════════════════════════════════════════════╝"
