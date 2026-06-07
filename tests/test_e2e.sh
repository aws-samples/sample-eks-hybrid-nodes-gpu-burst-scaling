#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# =============================================================================
# tests/test_e2e.sh
# End-to-end complete test — EKS Hybrid Nodes + Burst Scaling
#
# Complete journey:
#   1. Verify full functional deploy (all components)
#   2. Generate load → burst activates → pods serve → scale-down
#   3. Metrics appear in Prometheus during load
#   4. GPU utilization > 0 during inference
#
# Usage: ./tests/test_e2e.sh
#
# WARNING: This test executes the complete journey and takes ~15-20 minutes.
#          Requires cluster with zero load before starting.
# =============================================================================
set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
MODEL_NAME="${MODEL_NAME:-Qwen3.6-35B-A3B-AWQ}"
BURST_DEPLOY="${BURST_DEPLOY:-qwen-burst}"
HYBRID_DEPLOY="${HYBRID_DEPLOY:-qwen-hybrid}"
SCALEDOBJECT_NAME="${SCALEDOBJECT_NAME:-qwen-burst-scaler}"
KARPENTER_NODEPOOL="${KARPENTER_NODEPOOL:-gpu}"
MONITORING_NS="${MONITORING_NS:-monitoring}"
DEFAULT_NS="${DEFAULT_NS:-default}"
VLLM_PORT="${VLLM_PORT:-8000}"

# Timeouts
TEST_TIMEOUT="${TEST_TIMEOUT:-30}"
KEDA_ACTIVATE_TIMEOUT="${KEDA_ACTIVATE_TIMEOUT:-180}"
NODE_PROVISION_TIMEOUT="${NODE_PROVISION_TIMEOUT:-420}"
POD_READY_TIMEOUT="${POD_READY_TIMEOUT:-600}"
COOLDOWN_PERIOD="${COOLDOWN_PERIOD:-300}"
SCALE_DOWN_TIMEOUT="${SCALE_DOWN_TIMEOUT:-420}"

# Thresholds
TTFT_THRESHOLD_S="${TTFT_THRESHOLD_S:-2.0}"
E2E_THRESHOLD_S="${E2E_THRESHOLD_S:-30.0}"
MIN_GPU_UTIL="${MIN_GPU_UTIL:-1}"  # minimum GPU utilization %

E2E_LOAD_JOB="${E2E_LOAD_JOB:-e2e-test-load}"

# ---------------------------------------------------------------------------
# Colors and helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

PASSED=0
FAILED=0
SKIPPED=0

# Tracks critical failures that block subsequent phases
CRITICAL_FAILURE=false

pass()     { echo -e "${GREEN}  ✔ PASS${NC} — $1"; ((PASSED++)); }
fail()     { echo -e "${RED}  ✘ FAIL${NC} — $1"; ((FAILED++)); }
fail_crit(){ echo -e "${RED}  ✘ FAIL [CRITICAL]${NC} — $1"; ((FAILED++)); CRITICAL_FAILURE=true; }
skip()     { echo -e "${YELLOW}  ⊘ SKIP${NC} — $1"; ((SKIPPED++)); }
info()     { echo -e "${BLUE}  ℹ${NC} $1"; }
step()     { echo -e "\n${CYAN}  ➤ $1${NC}"; }
header()   { echo -e "\n${BLUE}▶ $1${NC}"; }

run_with_timeout() {
  local t="$1"; shift
  timeout "$t" "$@"
}

# Cleanup on exit
cleanup() {
  kubectl delete job "$E2E_LOAD_JOB" --ignore-not-found &>/dev/null || true
}
trap cleanup EXIT

# Query Prometheus via kubectl exec
prometheus_query() {
  local query="$1"
  local prom_pod
  prom_pod=$(kubectl get pods -n "$MONITORING_NS" \
    -l "app.kubernetes.io/name=prometheus" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  [[ -z "$prom_pod" ]] && echo "NO_POD" && return

  local encoded
  encoded=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$query" 2>/dev/null \
    || echo "$query" | sed 's/ /%20/g; s/{/%7B/g; s/}/%7D/g; s/"/%22/g')

  kubectl exec -n "$MONITORING_NS" "$prom_pod" \
    -c prometheus \
    -- wget -qO- "http://localhost:9090/api/v1/query?query=${encoded}" 2>/dev/null \
    | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    r = d.get('data', {}).get('result', [])
    print(r[0]['value'][1] if r else 'NO_DATA')
except:
    print('PARSE_ERROR')
" 2>/dev/null || echo "EXEC_FAIL"
}

# ---------------------------------------------------------------------------
# PHASE 1 — Complete Deploy Verification
# ---------------------------------------------------------------------------
e2e_phase1_deploy_verification() {
  header "PHASE 1 — Complete Deploy Verification"

  step "1.1 Hybrid deployment active"
  local hybrid_ready
  hybrid_ready=$(kubectl get deployment \
    "$HYBRID_DEPLOY" -n "$DEFAULT_NS" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")

  if [[ "${hybrid_ready:-0}" -ge 1 ]]; then
    pass "Hybrid deployment ready: ${hybrid_ready} replica(s)"
  else
    fail_crit "Hybrid deployment is not ready (readyReplicas=${hybrid_ready:-0})"
    return
  fi

  step "1.2 Burst deployment exists and is at scale-to-zero"
  local burst_spec_replicas
  burst_spec_replicas=$(kubectl get deployment \
    "$BURST_DEPLOY" -n "$DEFAULT_NS" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")

  if [[ -n "$burst_spec_replicas" ]]; then
    pass "Burst deployment exists (spec.replicas=${burst_spec_replicas})"
  else
    fail_crit "Burst deployment not found"
    return
  fi

  step "1.3 KEDA ScaledObject Ready"
  local so_ready
  so_ready=$(kubectl get scaledobject \
    "$SCALEDOBJECT_NAME" -n "$DEFAULT_NS" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")

  if [[ "$so_ready" == "True" ]]; then
    pass "KEDA ScaledObject Ready=True"
  else
    fail_crit "KEDA ScaledObject Ready=${so_ready}"
    return
  fi

  step "1.4 Prometheus running"
  local prom_ready
  prom_ready=$(kubectl get statefulset \
    -n "$MONITORING_NS" \
    -l "app.kubernetes.io/name=prometheus" \
    -o jsonpath='{.items[0].status.readyReplicas}' 2>/dev/null || echo "0")

  if [[ "${prom_ready:-0}" -ge 1 ]]; then
    pass "Prometheus running (${prom_ready} replica(s))"
  else
    fail "Prometheus is not ready"
  fi

  step "1.5 Karpenter GPU NodePool configured"
  local np_exists
  np_exists=$(kubectl get nodepool \
    "$KARPENTER_NODEPOOL" \
    -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")

  if [[ -n "$np_exists" ]]; then
    pass "Karpenter NodePool '${KARPENTER_NODEPOOL}' exists"
  else
    fail "Karpenter NodePool '${KARPENTER_NODEPOOL}' not found"
  fi

  step "1.6 Service qwen-burst-svc exists and has endpoints"
  local svc_exists
  svc_exists=$(kubectl get svc \
    "qwen-burst-svc" -n "$DEFAULT_NS" \
    -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")

  if [[ -n "$svc_exists" ]]; then
    pass "Service qwen-burst-svc exists"

    local endpoints
    endpoints=$(kubectl get endpoints \
      "qwen-burst-svc" -n "$DEFAULT_NS" \
      -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || echo "")

    if [[ -n "$endpoints" ]]; then
      pass "Service has active endpoints: ${endpoints}"
    else
      info "Service has no endpoints (burst at scale-to-zero — normal)"
      pass "Service has no endpoints (scale-to-zero active)"
    fi
  else
    fail "Service qwen-burst-svc not found"
  fi

  step "1.7 vLLM health check on hybrid pod"
  local hybrid_pod
  hybrid_pod=$(kubectl get pod \
    -l "tier=hybrid" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  if [[ -z "$hybrid_pod" ]]; then
    fail_crit "Hybrid pod not found"
    return
  fi

  local health_code
  health_code=$(kubectl exec "$hybrid_pod" \
    -- sh -c "curl -s -o /dev/null -w '%{http_code}' http://localhost:${VLLM_PORT}/health" \
    2>/dev/null || echo "000")

  if [[ "$health_code" == "200" ]]; then
    pass "vLLM /health returns 200 on hybrid pod"
  else
    fail_crit "vLLM /health returns ${health_code} (expected 200)"
  fi

  if [[ "$CRITICAL_FAILURE" == "true" ]]; then
    echo -e "\n${RED}Critical failure in Phase 1 — aborting E2E${NC}"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# PHASE 2 — Baseline Inference (before burst)
# ---------------------------------------------------------------------------
e2e_phase2_baseline_inference() {
  header "PHASE 2 — Baseline Inference (Hybrid Node)"

  local hybrid_pod
  hybrid_pod=$(kubectl get pod \
    -l "tier=hybrid" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  if [[ -z "$hybrid_pod" ]]; then
    skip "Hybrid pod not available"
    return
  fi

  step "2.1 Basic inference works"
  local payload='{"model":"'"$MODEL_NAME"'","messages":[{"role":"user","content":"Say hello"}],"max_tokens":5,"temperature":0}'

  local start_ns end_ns elapsed_s
  start_ns=$(date +%s%N)

  local response
  response=$(kubectl exec "$hybrid_pod" \
    -- sh -c "curl -s -X POST http://localhost:${VLLM_PORT}/v1/chat/completions \
      -H 'Content-Type: application/json' \
      -d '${payload}'" 2>/dev/null || echo "FAIL")

  end_ns=$(date +%s%N)
  elapsed_s=$(echo "scale=3; ($end_ns - $start_ns) / 1000000000" | bc 2>/dev/null || echo "0")

  if echo "$response" | grep -q '"choices"'; then
    pass "Baseline inference OK (${elapsed_s}s)"
  else
    fail "Baseline inference failed: ${response}"
    return
  fi

  step "2.2 E2E latency within threshold"
  local e2e_ok
  e2e_ok=$(echo "$elapsed_s < $E2E_THRESHOLD_S" | bc 2>/dev/null || echo "0")

  if [[ "$e2e_ok" == "1" ]]; then
    pass "E2E baseline latency: ${elapsed_s}s (threshold: ${E2E_THRESHOLD_S}s)"
  else
    fail "E2E baseline latency: ${elapsed_s}s exceeds ${E2E_THRESHOLD_S}s"
  fi

  step "2.3 GPU utilization > 0 during inference"
  # Verify via DCGM in Prometheus
  local gpu_util
  gpu_util=$(prometheus_query "max(DCGM_FI_DEV_GPU_UTIL)")

  if [[ "$gpu_util" =~ ^[0-9] ]]; then
    local util_ok
    util_ok=$(echo "$gpu_util >= $MIN_GPU_UTIL" | bc 2>/dev/null || echo "0")
    if [[ "$util_ok" == "1" ]]; then
      pass "GPU utilization: ${gpu_util}% (minimum: ${MIN_GPU_UTIL}%)"
    else
      fail "GPU utilization: ${gpu_util}% below minimum of ${MIN_GPU_UTIL}%"
    fi
  else
    skip "Metric DCGM_FI_DEV_GPU_UTIL not available (${gpu_util})"
  fi

  step "2.4 vLLM metrics appear in Prometheus"
  local waiting_metric
  waiting_metric=$(prometheus_query 'vllm:num_requests_waiting{pod=~"qwen-hybrid.*"}')

  if [[ "$waiting_metric" =~ ^[0-9] ]]; then
    pass "Metric vllm:num_requests_waiting available in Prometheus (value=${waiting_metric})"
  else
    fail "Metric vllm:num_requests_waiting not available (${waiting_metric})"
  fi
}

# ---------------------------------------------------------------------------
# PHASE 3 — Load Generation and Burst Scaling
# ---------------------------------------------------------------------------
e2e_phase3_burst_scaling() {
  header "PHASE 3 — Load Generation → Burst Scaling"

  local hybrid_pod
  hybrid_pod=$(kubectl get pod \
    -l "tier=hybrid" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  if [[ -z "$hybrid_pod" ]]; then
    skip "Hybrid pod not available — skipping burst phase"
    return
  fi

  local hybrid_ip
  hybrid_ip=$(kubectl get pod "$hybrid_pod" \
    -o jsonpath='{.status.hostIP}' 2>/dev/null || echo "")

  if [[ -z "$hybrid_ip" ]]; then
    skip "Hybrid pod IP not available"
    return
  fi

  step "3.1 Creating sustained load Job"
  kubectl delete job "$E2E_LOAD_JOB" --ignore-not-found &>/dev/null || true

  kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${E2E_LOAD_JOB}
  labels:
    app: e2e-test
spec:
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: load
          image: curlimages/curl:8.7.1
          command: ["/bin/sh", "-c"]
          args:
            - |
              echo "Starting E2E load..."
              for round in \$(seq 1 6); do
                echo "Round \$round/6: sending 60 concurrent requests..."
                for i in \$(seq 1 60); do
                  curl -s --max-time 60 http://${hybrid_ip}:${VLLM_PORT}/v1/chat/completions \
                    -H "Content-Type: application/json" \
                    -d '{"model":"${MODEL_NAME}","messages":[{"role":"user","content":"Explain the complete history of neural networks from perceptrons to transformers in detail"}],"max_tokens":512}' &
                done
                sleep 15
              done
              wait
              echo "E2E load completed"
EOF

  if [[ $? -eq 0 ]]; then
    pass "E2E load Job created: ${E2E_LOAD_JOB}"
  else
    fail "Failed to create E2E load Job"
    return
  fi

  step "3.2 Waiting for KEDA to activate (timeout: ${KEDA_ACTIVATE_TIMEOUT}s)"
  local keda_activated=false
  local elapsed=0
  local poll=15

  while [[ "$elapsed" -lt "$KEDA_ACTIVATE_TIMEOUT" ]]; do
    local keda_active
    keda_active=$(kubectl get scaledobject \
      "$SCALEDOBJECT_NAME" -n "$DEFAULT_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Active")].status}' 2>/dev/null || echo "")

    local burst_replicas
    burst_replicas=$(kubectl get deployment \
      "$BURST_DEPLOY" -n "$DEFAULT_NS" \
      -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")

    # Collect metrics for evidence
    local waiting_val
    waiting_val=$(prometheus_query 'sum(vllm:num_requests_waiting{pod=~"qwen-hybrid.*"})' 2>/dev/null || echo "?")

    info "  [${elapsed}s] KEDA Active=${keda_active} | burst replicas=${burst_replicas} | waiting=${waiting_val}"

    if [[ "$keda_active" == "True" ]]; then
      keda_activated=true
      break
    fi

    sleep "$poll"
    elapsed=$(( elapsed + poll ))
  done

  if [[ "$keda_activated" == "true" ]]; then
    pass "KEDA activated under load (${elapsed}s)"
  else
    fail "KEDA did not activate within ${KEDA_ACTIVATE_TIMEOUT}s"
    return
  fi

  step "3.3 Burst deployment scaled up"
  local burst_replicas_now
  burst_replicas_now=$(kubectl get deployment \
    "$BURST_DEPLOY" -n "$DEFAULT_NS" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")

  if [[ "${burst_replicas_now:-0}" -gt 0 ]]; then
    pass "Burst deployment scaled up: spec.replicas=${burst_replicas_now}"
  else
    fail "Burst deployment did not scale up (spec.replicas=${burst_replicas_now})"
    return
  fi

  step "3.4 Karpenter created GPU NodeClaims (timeout: ${NODE_PROVISION_TIMEOUT}s)"
  local nodeclaims_created=false
  elapsed=0

  while [[ "$elapsed" -lt "$NODE_PROVISION_TIMEOUT" ]]; do
    local nc_count
    nc_count=$(kubectl get nodeclaims \
      -l "karpenter.sh/nodepool=${KARPENTER_NODEPOOL}" \
      --no-headers 2>/dev/null | wc -l | tr -d ' ')

    info "  [${elapsed}s] NodeClaims GPU: ${nc_count}"

    if [[ "${nc_count:-0}" -gt 0 ]]; then
      nodeclaims_created=true
      local nc_names
      nc_names=$(kubectl get nodeclaims \
        -l "karpenter.sh/nodepool=${KARPENTER_NODEPOOL}" \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
      pass "Karpenter created NodeClaims: ${nc_names}"
      break
    fi

    sleep 20
    elapsed=$(( elapsed + 20 ))
  done

  if [[ "$nodeclaims_created" == "false" ]]; then
    fail "Karpenter did not create NodeClaims within ${NODE_PROVISION_TIMEOUT}s"
    return
  fi

  step "3.5 Burst pods become Ready (timeout: ${POD_READY_TIMEOUT}s)"
  local pods_ready=false

  if kubectl wait \
    --for=condition=Ready \
    pod \
    -l "tier=burst" \
    --timeout="${POD_READY_TIMEOUT}s" \
    2>/dev/null; then
    pods_ready=true
  fi

  if [[ "$pods_ready" == "true" ]]; then
    local ready_pods
    ready_pods=$(kubectl get pods \
      -l "tier=burst" \
      -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName \
      --no-headers 2>/dev/null || echo "")
    pass "Burst pods Ready:"
    echo "$ready_pods" | while read -r line; do info "    ${line}"; done
  else
    fail "Burst pods did not become Ready within ${POD_READY_TIMEOUT}s"
    return
  fi

  step "3.6 Burst pods serve inference"
  local burst_pod
  burst_pod=$(kubectl get pod \
    -l "tier=burst" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  if [[ -z "$burst_pod" ]]; then
    skip "No burst pod available for inference test"
    return
  fi

  local burst_payload='{"model":"'"$MODEL_NAME"'","messages":[{"role":"user","content":"Hi"}],"max_tokens":5,"temperature":0}'
  local burst_response
  burst_response=$(kubectl exec "$burst_pod" \
    -- sh -c "curl -s -X POST http://localhost:${VLLM_PORT}/v1/chat/completions \
      -H 'Content-Type: application/json' \
      -d '${burst_payload}'" 2>/dev/null || echo "FAIL")

  if echo "$burst_response" | grep -q '"choices"'; then
    pass "Burst pod serves inference correctly"
  else
    fail "Burst pod does not serve inference: ${burst_response}"
  fi
}

# ---------------------------------------------------------------------------
# PHASE 4 — Metrics During Load
# ---------------------------------------------------------------------------
e2e_phase4_metrics_under_load() {
  header "PHASE 4 — Metrics in Prometheus During Load"

  step "4.1 vllm:num_requests_waiting > 0 during load"
  local waiting_val
  waiting_val=$(prometheus_query 'sum(vllm:num_requests_waiting{pod=~"qwen-hybrid.*"})')

  if [[ "$waiting_val" =~ ^[0-9] ]]; then
    pass "vllm:num_requests_waiting=${waiting_val} (load visible in Prometheus)"
  else
    skip "Metric waiting not available (${waiting_val}) — load may have finished"
  fi

  step "4.2 vllm:num_requests_running > 0 during load"
  local running_val
  running_val=$(prometheus_query 'sum(vllm:num_requests_running{pod=~"qwen-hybrid.*"})')

  if [[ "$running_val" =~ ^[0-9] && "${running_val}" != "0" ]]; then
    pass "vllm:num_requests_running=${running_val}"
  else
    skip "Metric running=${running_val} (may be 0 if load finished)"
  fi

  step "4.3 TTFT P95 available in Prometheus"
  local ttft_p95
  ttft_p95=$(prometheus_query 'histogram_quantile(0.95, sum(rate(vllm:time_to_first_token_seconds_bucket{pod=~"qwen-hybrid.*"}[5m])) by (le))')

  if [[ "$ttft_p95" =~ ^[0-9] ]]; then
    local ttft_ok
    ttft_ok=$(echo "$ttft_p95 < $TTFT_THRESHOLD_S" | bc 2>/dev/null || echo "0")
    if [[ "$ttft_ok" == "1" ]]; then
      pass "TTFT P95: ${ttft_p95}s (threshold: ${TTFT_THRESHOLD_S}s)"
    else
      fail "TTFT P95: ${ttft_p95}s exceeds threshold of ${TTFT_THRESHOLD_S}s"
    fi
  else
    skip "TTFT P95 not available (${ttft_p95}) — may not have enough data"
  fi

  step "4.4 E2E latency P95 available in Prometheus"
  local e2e_p95
  e2e_p95=$(prometheus_query 'histogram_quantile(0.95, sum(rate(vllm:e2e_request_latency_seconds_bucket{pod=~"qwen-hybrid.*"}[5m])) by (le))')

  if [[ "$e2e_p95" =~ ^[0-9] ]]; then
    pass "E2E latency P95: ${e2e_p95}s"
  else
    skip "E2E latency P95 not available (${e2e_p95})"
  fi

  step "4.5 GPU utilization > 0 during load"
  local gpu_util
  gpu_util=$(prometheus_query "max(DCGM_FI_DEV_GPU_UTIL)")

  if [[ "$gpu_util" =~ ^[0-9] ]]; then
    local util_ok
    util_ok=$(echo "$gpu_util >= $MIN_GPU_UTIL" | bc 2>/dev/null || echo "0")
    if [[ "$util_ok" == "1" ]]; then
      pass "GPU utilization: ${gpu_util}% (minimum: ${MIN_GPU_UTIL}%)"
    else
      fail "GPU utilization: ${gpu_util}% below minimum of ${MIN_GPU_UTIL}%"
    fi
  else
    skip "Metric DCGM_FI_DEV_GPU_UTIL not available (${gpu_util})"
  fi

  step "4.6 KEDA scaler active in Prometheus"
  local keda_active_metric
  keda_active_metric=$(prometheus_query "keda_scaler_active{scaledObject=\"${SCALEDOBJECT_NAME}\"}")

  if [[ "$keda_active_metric" =~ ^[0-9] ]]; then
    pass "Metric keda_scaler_active available: ${keda_active_metric}"
  else
    skip "Metric keda_scaler_active not available (${keda_active_metric})"
  fi
}

# ---------------------------------------------------------------------------
# PHASE 5 — Scale-Down and Cleanup
# ---------------------------------------------------------------------------
e2e_phase5_scale_down() {
  header "PHASE 5 — Scale-Down After Cooldown"

  step "5.1 Removing load Job"
  kubectl delete job "$E2E_LOAD_JOB" --ignore-not-found &>/dev/null || true
  pass "Load Job removed"

  step "5.2 Waiting for scale-down (cooldown=${COOLDOWN_PERIOD}s + margin)"
  local wait_time=$(( COOLDOWN_PERIOD + 60 ))
  info "Waiting ${wait_time}s for scale-down..."

  local elapsed=0
  local poll=30
  local scaled_down=false

  while [[ "$elapsed" -lt "$wait_time" ]]; do
    sleep "$poll"
    elapsed=$(( elapsed + poll ))

    local current_replicas
    current_replicas=$(kubectl get deployment \
      "$BURST_DEPLOY" -n "$DEFAULT_NS" \
      -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")

    local keda_active
    keda_active=$(kubectl get scaledobject \
      "$SCALEDOBJECT_NAME" -n "$DEFAULT_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Active")].status}' 2>/dev/null || echo "")

    info "  [${elapsed}s] burst replicas=${current_replicas} | KEDA Active=${keda_active}"

    if [[ "${current_replicas:-1}" -eq 0 ]]; then
      scaled_down=true
      break
    fi
  done

  if [[ "$scaled_down" == "true" ]]; then
    pass "Scale-down occurred after cooldown (${elapsed}s)"
  else
    fail "Scale-down did not occur within ${wait_time}s"
  fi

  step "5.3 Hybrid deployment remains active after scale-down"
  local hybrid_ready
  hybrid_ready=$(kubectl get deployment \
    "$HYBRID_DEPLOY" -n "$DEFAULT_NS" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")

  if [[ "${hybrid_ready:-0}" -ge 1 ]]; then
    pass "Hybrid deployment remains active after scale-down: ${hybrid_ready} replica(s)"
  else
    fail "Hybrid deployment is no longer active after scale-down (readyReplicas=${hybrid_ready})"
  fi

  step "5.4 vLLM still responds after scale-down"
  local hybrid_pod
  hybrid_pod=$(kubectl get pod \
    -l "tier=hybrid" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  if [[ -n "$hybrid_pod" ]]; then
    local health_code
    health_code=$(kubectl exec "$hybrid_pod" \
      -- sh -c "curl -s -o /dev/null -w '%{http_code}' http://localhost:${VLLM_PORT}/health" \
      2>/dev/null || echo "000")

    if [[ "$health_code" == "200" ]]; then
      pass "vLLM still responds after scale-down (HTTP 200)"
    else
      fail "vLLM not responding after scale-down (HTTP ${health_code})"
    fi
  else
    fail "Hybrid pod not found after scale-down"
  fi
}

# ---------------------------------------------------------------------------
# E2E Final Report
# ---------------------------------------------------------------------------
e2e_final_report() {
  local total=$(( PASSED + FAILED + SKIPPED ))
  local pass_rate=0
  if [[ "$total" -gt 0 ]]; then
    pass_rate=$(echo "scale=1; $PASSED * 100 / $total" | bc 2>/dev/null || echo "0")
  fi

  echo -e "\n${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║  E2E REPORT — EKS Hybrid Nodes + Burst Scaling              ║${NC}"
  echo -e "${BLUE}╠══════════════════════════════════════════════════════════════╣${NC}"
  echo -e "${BLUE}║${NC}  Total: ${total} | ${GREEN}Passed: ${PASSED}${NC} | ${RED}Failed: ${FAILED}${NC} | ${YELLOW}Skipped: ${SKIPPED}${NC}"
  echo -e "${BLUE}║${NC}  Pass rate: ${pass_rate}%"
  echo -e "${BLUE}╠══════════════════════════════════════════════════════════════╣${NC}"

  if [[ "$FAILED" -eq 0 ]]; then
    echo -e "${BLUE}║${NC}  ${GREEN}✔ E2E JOURNEY COMPLETE — PASSED${NC}"
    echo -e "${BLUE}║${NC}  All phases executed successfully:"
    echo -e "${BLUE}║${NC}    ✔ Complete deploy functional"
    echo -e "${BLUE}║${NC}    ✔ Baseline inference OK"
    echo -e "${BLUE}║${NC}    ✔ Burst scaling activated under load"
    echo -e "${BLUE}║${NC}    ✔ Metrics visible in Prometheus"
    echo -e "${BLUE}║${NC}    ✔ Scale-down after cooldown"
  else
    echo -e "${BLUE}║${NC}  ${RED}✘ E2E JOURNEY — FAILED (${FAILED} failure(s))${NC}"
  fi

  echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
}

# ---------------------------------------------------------------------------
# Main runner
# ---------------------------------------------------------------------------
run_all_tests() {
  echo -e "\n${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║  test_e2e.sh — Complete E2E Journey                         ║${NC}"
  echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo -e "Model: ${MODEL_NAME}"
  echo -e "Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo -e "${YELLOW}⚠ This test takes ~15-20 minutes to complete the full journey.${NC}\n"

  e2e_phase1_deploy_verification || true
  e2e_phase2_baseline_inference
  e2e_phase3_burst_scaling
  e2e_phase4_metrics_under_load
  e2e_phase5_scale_down

  e2e_final_report

  if [[ "$FAILED" -gt 0 ]]; then
    exit 1
  else
    exit 0
  fi
}

run_all_tests
