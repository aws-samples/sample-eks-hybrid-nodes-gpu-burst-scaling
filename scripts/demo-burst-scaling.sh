#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# =============================================================================
# demo-burst-scaling.sh — Demonstrate hybrid-to-cloud burst scaling
#
# Purpose:
#   Drives a sustained load against qwen-burst-svc to saturate the hybrid
#   pod's request queue, triggering KEDA to scale the burst deployment from 0
#   to 1+. Monitors Prometheus metrics, Karpenter node provisioning, burst pod
#   readiness, and finally checks that the burst pods actually serve requests.
#
#   The load is a constant arrival rate (CLIENTS parallel loops, each sending
#   one request at a time for DURATION seconds), not a one-shot flood: requests
#   already queued on the CPU pod never migrate, so the burst tier only helps
#   if requests keep arriving after the GPU pods are Ready (~6-10 min).
#
# Environment Variables:
#   HYBRID_IP   — ClusterIP of qwen-burst-svc or host IP of the hybrid pod (auto-detected)
#   VLLM_PORT   — vLLM serving port (default: 8000)
#   CLIENTS     — Parallel client loops (default: 48)
#   DURATION    — Load duration in seconds (default: 1200)
#   MAX_TOKENS  — max_tokens per request (default: 256)
#
# Prerequisites:
#   - kubectl configured for the EKS cluster
#   - Burst scaling manifests deployed (manifests/burst-scaling/)
#   - Prometheus stack running in the monitoring namespace
#
# Usage:
#   ./scripts/demo-burst-scaling.sh
#   HYBRID_IP=10.100.0.50 ./scripts/demo-burst-scaling.sh
#   CLIENTS=64 DURATION=900 ./scripts/demo-burst-scaling.sh
# =============================================================================
set -uo pipefail

HYBRID_IP="${HYBRID_IP:-$(kubectl get svc qwen-burst-svc -o jsonpath='{.spec.clusterIP}' 2>/dev/null || kubectl get pod -l tier=hybrid -o jsonpath='{.items[0].status.hostIP}' 2>/dev/null || echo 10.100.0.137)}"
VLLM_PORT="${VLLM_PORT:-8000}"
CLIENTS="${CLIENTS:-48}"
DURATION="${DURATION:-1200}"
MAX_TOKENS="${MAX_TOKENS:-256}"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Hybrid-to-Cloud Burst Scaling Demo                         ║"
echo "║  Target: ${HYBRID_IP}:${VLLM_PORT}                         ║"
echo "║  Load: ${CLIENTS} clients for ${DURATION}s (max_tokens ${MAX_TOKENS})"
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
  activeDeadlineSeconds: $((DURATION + 900))
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: load
          image: curlimages/curl
          command: ["/bin/sh", "-c"]
          args:
            - |
              END=\$((\$(date +%s) + ${DURATION}))
              echo "Starting ${CLIENTS} clients until \$(date -d @\$END 2>/dev/null || echo \$END)"
              for c in \$(seq 1 ${CLIENTS}); do
                (
                  n=0
                  while [ \$(date +%s) -lt \$END ]; do
                    curl -s -o /dev/null -m 600 http://${HYBRID_IP}:${VLLM_PORT}/v1/chat/completions \
                      -H "Content-Type: application/json" \
                      -d '{"model":"Qwen2.5-1.5B-Instruct","messages":[{"role":"user","content":"Write a detailed essay about the history of artificial intelligence"}],"max_tokens":${MAX_TOKENS}}'
                    n=\$((n + 1))
                  done
                  echo "client \$c done: \$n requests"
                ) &
              done
              wait
EOF
echo "Load job submitted."
echo ""

prom_query() {
  local q
  q=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$1")
  kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \
    wget -qO- "http://localhost:9090/api/v1/query?query=${q}" 2>/dev/null | \
    python3 -c "import sys,json;d=json.load(sys.stdin);r=d['data']['result'];print(r[0]['value'][1] if r else '0')" 2>/dev/null
}

echo "=== Step 2: Monitoring metrics (polling every 15s) ==="
for i in $(seq 1 8); do
  sleep 15
  WAITING=$(prom_query 'sum(vllm:num_requests_waiting{pod=~"qwen-hybrid.*"})')
  RUNNING=$(prom_query 'sum(vllm:num_requests_running{pod=~"qwen-hybrid.*"})')
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

echo "=== Step 5: Verifying that the burst tier serves traffic ==="
sleep 60
BURST_RUNNING=$(prom_query 'sum(vllm:num_requests_running{pod=~"qwen-burst.*"})')
BURST_TOKPS=$(prom_query 'sum(rate(vllm:generation_tokens_total{pod=~"qwen-burst.*"}[1m]))')
HYBRID_TOKPS=$(prom_query 'sum(rate(vllm:generation_tokens_total{pod=~"qwen-hybrid.*"}[1m]))')
echo "  burst running=${BURST_RUNNING} | tokens/s burst=${BURST_TOKPS} hybrid=${HYBRID_TOKPS}"
echo ""
if python3 -c "import sys; sys.exit(0 if float('${BURST_RUNNING:-0}' or 0) > 0 else 1)" 2>/dev/null; then
  RESULT="Burst pods are serving requests."
else
  RESULT="WARNING: burst pods are not serving requests yet."
fi
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  ${RESULT}"
echo "║  Load keeps running for ${DURATION}s; stop it early with:"
echo "║    kubectl delete job burst-demo-load"
echo "║  Scale-down: KEDA cooldown 300s, then Karpenter consolidates"
echo "║  empty GPU nodes (consolidateAfter 600s, one node at a time)."
echo "║  Run: watch kubectl get deploy qwen-burst; kubectl get nodeclaims"
echo "╚══════════════════════════════════════════════════════════════╝"
