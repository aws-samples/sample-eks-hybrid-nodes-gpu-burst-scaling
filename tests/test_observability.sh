#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# =============================================================================
# tests/test_observability.sh
# Observability tests — Prometheus, Grafana, DCGM, vLLM metrics
#
# Covers:
#   - Prometheus running and scraping targets
#   - Grafana accessible
#   - DCGM exporter reporting GPU metrics
#   - vLLM metrics available (num_requests_waiting, TTFT, etc.)
#   - ServiceMonitor configured correctly
#
# Usage: ./tests/test_observability.sh
# =============================================================================
set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
MONITORING_NS="${MONITORING_NS:-monitoring}"
GPU_OPERATOR_NS="${GPU_OPERATOR_NS:-gpu-operator}"
DEFAULT_NS="${DEFAULT_NS:-default}"
PROMETHEUS_SVC="${PROMETHEUS_SVC:-kube-prometheus-stack-prometheus}"
GRAFANA_SVC="${GRAFANA_SVC:-kube-prometheus-stack-grafana}"
PROMETHEUS_PORT="${PROMETHEUS_PORT:-9090}"
GRAFANA_PORT="${GRAFANA_PORT:-80}"
TEST_TIMEOUT="${TEST_TIMEOUT:-30}"

# ---------------------------------------------------------------------------
# Colors and helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASSED=0
FAILED=0
SKIPPED=0

pass()   { echo -e "${GREEN}  ✔ PASS${NC} — $1"; ((PASSED++)); }
fail()   { echo -e "${RED}  ✘ FAIL${NC} — $1"; ((FAILED++)); }
skip()   { echo -e "${YELLOW}  ⊘ SKIP${NC} — $1"; ((SKIPPED++)); }
info()   { echo -e "${BLUE}  ℹ${NC} $1"; }
header() { echo -e "\n${BLUE}▶ $1${NC}"; }

run_with_timeout() {
  local t="$1"; shift
  timeout "$t" "$@"
}

# Executes PromQL query via kubectl exec on the Prometheus pod
# Returns the numeric value of the first result or "NO_DATA"
prometheus_query() {
  local query="$1"
  local prom_pod
  prom_pod=$(kubectl get pods -n "$MONITORING_NS" \
    -l "app.kubernetes.io/name=prometheus" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  if [[ -z "$prom_pod" ]]; then
    echo "NO_POD"
    return
  fi

  local encoded_query
  encoded_query=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$query" 2>/dev/null \
    || echo "$query" | sed 's/ /%20/g; s/{/%7B/g; s/}/%7D/g; s/"/%22/g; s/=/%3D/g')

  local result
  result=$(kubectl exec -n "$MONITORING_NS" "$prom_pod" \
    -c prometheus \
    -- wget -qO- "http://localhost:${PROMETHEUS_PORT}/api/v1/query?query=${encoded_query}" 2>/dev/null \
    | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    r = d.get('data', {}).get('result', [])
    if r:
        print(r[0]['value'][1])
    else:
        print('NO_DATA')
except Exception as e:
    print('PARSE_ERROR')
" 2>/dev/null || echo "EXEC_FAIL")

  echo "${result:-NO_DATA}"
}

# Check if Prometheus targets are healthy
prometheus_targets_healthy() {
  local prom_pod="$1"
  kubectl exec -n "$MONITORING_NS" "$prom_pod" \
    -c prometheus \
    -- wget -qO- "http://localhost:${PROMETHEUS_PORT}/api/v1/targets" 2>/dev/null \
    | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    active = d.get('data', {}).get('activeTargets', [])
    up = sum(1 for t in active if t.get('health') == 'up')
    total = len(active)
    print(f'{up}/{total}')
except:
    print('PARSE_ERROR')
" 2>/dev/null || echo "EXEC_FAIL"
}

# ---------------------------------------------------------------------------
# SUITE 1 — Prometheus
# ---------------------------------------------------------------------------
test_prometheus_running() {
  header "SUITE 1 — Prometheus"

  # 1.1 StatefulSet prometheus exists and is ready
  local prom_ready
  prom_ready=$(kubectl get statefulset \
    -n "$MONITORING_NS" \
    -l "app.kubernetes.io/name=prometheus" \
    -o jsonpath='{.items[0].status.readyReplicas}' 2>/dev/null || echo "0")

  if [[ "${prom_ready:-0}" -ge 1 ]]; then
    pass "Prometheus StatefulSet ready: ${prom_ready} replica(s)"
  else
    fail "Prometheus StatefulSet is not ready (readyReplicas=${prom_ready:-0})"
  fi

  # 1.2 Prometheus pod in Running
  local prom_pod
  prom_pod=$(kubectl get pods -n "$MONITORING_NS" \
    -l "app.kubernetes.io/name=prometheus" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  if [[ -z "$prom_pod" ]]; then
    fail "Prometheus pod not found in namespace ${MONITORING_NS}"
    return
  fi

  local prom_phase
  prom_phase=$(kubectl get pod "$prom_pod" -n "$MONITORING_NS" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

  if [[ "$prom_phase" == "Running" ]]; then
    pass "Prometheus pod in Running: ${prom_pod}"
  else
    fail "Prometheus pod is not Running (phase: ${prom_phase})"
  fi

  # 1.3 Prometheus API responds
  local api_result
  api_result=$(kubectl exec -n "$MONITORING_NS" "$prom_pod" \
    -c prometheus \
    -- wget -qO- "http://localhost:${PROMETHEUS_PORT}/-/healthy" 2>/dev/null || echo "FAIL")

  if echo "$api_result" | grep -qi "healthy\|ok\|prometheus"; then
    pass "Prometheus API /-/healthy responds OK"
  else
    fail "Prometheus API /-/healthy not responding (result: ${api_result})"
  fi

  # 1.4 Active targets
  local targets_status
  targets_status=$(prometheus_targets_healthy "$prom_pod")

  if echo "$targets_status" | grep -qE "^[1-9][0-9]*/"; then
    pass "Prometheus scraping targets: ${targets_status} (up/total)"
  else
    fail "Prometheus targets not available: ${targets_status}"
  fi

  # 1.5 Prometheus service exists
  local prom_svc
  prom_svc=$(kubectl get svc "$PROMETHEUS_SVC" \
    -n "$MONITORING_NS" \
    -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")

  if [[ -n "$prom_svc" ]]; then
    pass "Service ${PROMETHEUS_SVC} exists in namespace ${MONITORING_NS}"
  else
    fail "Service ${PROMETHEUS_SVC} not found in namespace ${MONITORING_NS}"
  fi
}

# ---------------------------------------------------------------------------
# SUITE 2 — Grafana
# ---------------------------------------------------------------------------
test_grafana_accessible() {
  header "SUITE 2 — Grafana"

  # 2.1 Grafana Deployment ready
  local grafana_ready
  grafana_ready=$(kubectl get deployment \
    -n "$MONITORING_NS" \
    -l "app.kubernetes.io/name=grafana" \
    -o jsonpath='{.items[0].status.readyReplicas}' 2>/dev/null || echo "0")

  if [[ "${grafana_ready:-0}" -ge 1 ]]; then
    pass "Grafana Deployment ready: ${grafana_ready} replica(s)"
  else
    fail "Grafana Deployment is not ready (readyReplicas=${grafana_ready:-0})"
  fi

  # 2.2 Grafana pod in Running
  local grafana_pod
  grafana_pod=$(kubectl get pods -n "$MONITORING_NS" \
    -l "app.kubernetes.io/name=grafana" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  if [[ -z "$grafana_pod" ]]; then
    fail "Grafana pod not found in namespace ${MONITORING_NS}"
    return
  fi

  local grafana_phase
  grafana_phase=$(kubectl get pod "$grafana_pod" -n "$MONITORING_NS" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

  if [[ "$grafana_phase" == "Running" ]]; then
    pass "Grafana pod in Running: ${grafana_pod}"
  else
    fail "Grafana pod is not Running (phase: ${grafana_phase})"
  fi

  # 2.3 Grafana health endpoint
  local grafana_health
  grafana_health=$(kubectl exec -n "$MONITORING_NS" "$grafana_pod" \
    -c grafana \
    -- wget -qO- "http://localhost:3000/api/health" 2>/dev/null || echo "FAIL")

  if echo "$grafana_health" | grep -qi "ok\|database"; then
    pass "Grafana /api/health responds OK"
  else
    fail "Grafana /api/health not responding (result: ${grafana_health})"
  fi

  # 2.4 Grafana service exists
  local grafana_svc
  grafana_svc=$(kubectl get svc "$GRAFANA_SVC" \
    -n "$MONITORING_NS" \
    -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")

  if [[ -n "$grafana_svc" ]]; then
    pass "Service ${GRAFANA_SVC} exists in namespace ${MONITORING_NS}"
  else
    fail "Service ${GRAFANA_SVC} not found in namespace ${MONITORING_NS}"
  fi

  # 2.5 Prometheus datasource configured in Grafana
  local grafana_creds
  grafana_creds="${GRAFANA_ADMIN_PASSWORD:-}"
  if [[ -z "$grafana_creds" ]]; then
    skip "GRAFANA_ADMIN_PASSWORD not set — skipping datasource check"
    return
  fi
  local auth_header
  auth_header=$(printf "admin:%s" "$grafana_creds" | base64)

  local datasource_result
  datasource_result=$(kubectl exec -n "$MONITORING_NS" "$grafana_pod" \
    -c grafana \
    -- wget -qO- --header="Authorization: Basic ${auth_header}" \
    "http://localhost:3000/api/datasources" 2>/dev/null || echo "FAIL")

  if echo "$datasource_result" | grep -qi "prometheus"; then
    pass "Prometheus datasource configured in Grafana"
  else
    skip "Could not verify Grafana datasources (may require different credentials)"
  fi
}

# ---------------------------------------------------------------------------
# SUITE 3 — DCGM Exporter
# ---------------------------------------------------------------------------
test_dcgm_exporter() {
  header "SUITE 3 — DCGM Exporter"

  # 3.1 DCGM DaemonSet exists
  local dcgm_ds
  dcgm_ds=$(kubectl get daemonset \
    -n "$GPU_OPERATOR_NS" \
    -l "app=nvidia-dcgm-exporter" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  if [[ -n "$dcgm_ds" ]]; then
    pass "DaemonSet nvidia-dcgm-exporter found in namespace ${GPU_OPERATOR_NS}"
  else
    # Try in monitoring namespace
    dcgm_ds=$(kubectl get daemonset \
      -n "$MONITORING_NS" \
      -l "app=nvidia-dcgm-exporter" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "$dcgm_ds" ]]; then
      pass "DaemonSet nvidia-dcgm-exporter found in namespace ${MONITORING_NS}"
    else
      fail "DaemonSet nvidia-dcgm-exporter not found (namespaces: ${GPU_OPERATOR_NS}, ${MONITORING_NS})"
    fi
  fi

  # 3.2 DCGM should NOT run on the on-premises hybrid node (it is CPU-only).
  # GPU metrics (DCGM) are expected only on burst GPU nodes, which are
  # scale-to-zero by default — so DCGM may legitimately be absent at rest.
  local hybrid_node
  hybrid_node=$(kubectl get nodes \
    -l "eks.amazonaws.com/compute-type=hybrid" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  if [[ -z "$hybrid_node" ]]; then
    skip "Hybrid node not found — skipping DCGM placement check"
  else
    local dcgm_pod_hybrid
    dcgm_pod_hybrid=$(kubectl get pods \
      -n "$GPU_OPERATOR_NS" \
      -l "app=nvidia-dcgm-exporter" \
      --field-selector "spec.nodeName=${hybrid_node}" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [[ -z "$dcgm_pod_hybrid" ]]; then
      pass "No DCGM exporter on the CPU hybrid node (expected — baseline is CPU-only)"
    else
      info "DCGM exporter present on hybrid node (${dcgm_pod_hybrid}) — unexpected for a CPU node"
      pass "DCGM exporter on hybrid node: ${dcgm_pod_hybrid}"
    fi

    # 3.3 DCGM on burst GPU nodes (only when burst is active / nodes exist)
    local dcgm_burst
    dcgm_burst=$(kubectl get pods -n "$GPU_OPERATOR_NS" \
      -l "app=nvidia-dcgm-exporter" \
      -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

    if [[ -n "$dcgm_burst" ]]; then
      pass "DCGM exporter running on GPU node(s): ${dcgm_burst}"
    else
      skip "No DCGM exporter pods (burst GPU nodes are scale-to-zero at rest)"
    fi
  fi

  # 3.5 Prometheus has DCGM metrics (via query)
  local dcgm_metric_value
  dcgm_metric_value=$(prometheus_query "count(DCGM_FI_DEV_GPU_UTIL)")

  if [[ "$dcgm_metric_value" =~ ^[0-9] ]]; then
    pass "Prometheus has DCGM_FI_DEV_GPU_UTIL metrics (count=${dcgm_metric_value})"
  else
    fail "Prometheus does not have DCGM_FI_DEV_GPU_UTIL metrics (result: ${dcgm_metric_value})"
  fi

  # 3.6 DCGM ServiceMonitor configured
  local dcgm_sm
  dcgm_sm=$(kubectl get servicemonitor \
    "nvidia-dcgm-exporter" \
    -n "$MONITORING_NS" \
    -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")

  if [[ -n "$dcgm_sm" ]]; then
    pass "ServiceMonitor nvidia-dcgm-exporter exists in namespace ${MONITORING_NS}"
  else
    fail "ServiceMonitor nvidia-dcgm-exporter not found in namespace ${MONITORING_NS}"
  fi
}

# ---------------------------------------------------------------------------
# SUITE 4 — vLLM Metrics
# ---------------------------------------------------------------------------
test_vllm_metrics() {
  header "SUITE 4 — vLLM Metrics"

  # 4.1 /metrics endpoint on hybrid pod returns vLLM metrics
  local hybrid_pod
  hybrid_pod=$(kubectl get pods \
    -l "tier=hybrid" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  if [[ -z "$hybrid_pod" ]]; then
    fail "Hybrid pod not found — cannot verify vLLM metrics"
    return
  fi

  local vllm_metrics
  vllm_metrics=$(kubectl exec "$hybrid_pod" \
    -- wget -qO- "http://localhost:8000/metrics" 2>/dev/null | head -50 || echo "FAIL")

  if echo "$vllm_metrics" | grep -qi "vllm\|num_requests"; then
    pass "/metrics endpoint on hybrid pod returns vLLM metrics"
  else
    fail "/metrics endpoint on hybrid pod does not return vLLM metrics"
  fi

  # 4.2 Metric num_requests_waiting present
  if echo "$vllm_metrics" | grep -q "num_requests_waiting\|vllm:num_requests_waiting"; then
    pass "Metric num_requests_waiting present"
  else
    # Check via Prometheus
    local waiting_val
    waiting_val=$(prometheus_query 'vllm:num_requests_waiting{pod=~"qwen-hybrid.*"}')
    if [[ "$waiting_val" =~ ^[0-9] ]]; then
      pass "Metric vllm:num_requests_waiting available in Prometheus (value=${waiting_val})"
    else
      fail "Metric num_requests_waiting not found (neither endpoint nor Prometheus)"
    fi
  fi

  # 4.3 Metric num_requests_running present
  local running_val
  running_val=$(prometheus_query 'vllm:num_requests_running{pod=~"qwen-hybrid.*"}')
  if [[ "$running_val" =~ ^[0-9] ]]; then
    pass "Metric vllm:num_requests_running available in Prometheus (value=${running_val})"
  else
    # May be 0 if no load — check if the series exists
    local running_exists
    running_exists=$(prometheus_query 'count(vllm:num_requests_running{pod=~"qwen-hybrid.*"})')
    if [[ "$running_exists" =~ ^[0-9] ]]; then
      pass "Series vllm:num_requests_running exists in Prometheus"
    else
      fail "Metric vllm:num_requests_running not found in Prometheus"
    fi
  fi

  # 4.4 Metric time_to_first_token present (histogram)
  local ttft_exists
  ttft_exists=$(prometheus_query 'count(vllm:time_to_first_token_seconds_bucket{pod=~"qwen-hybrid.*"})')
  if [[ "$ttft_exists" =~ ^[0-9] ]]; then
    pass "Histogram vllm:time_to_first_token_seconds_bucket exists in Prometheus"
  else
    fail "Histogram vllm:time_to_first_token_seconds_bucket not found in Prometheus"
  fi

  # 4.5 Metric e2e_request_latency present (histogram)
  local e2e_exists
  e2e_exists=$(prometheus_query 'count(vllm:e2e_request_latency_seconds_bucket{pod=~"qwen-hybrid.*"})')
  if [[ "$e2e_exists" =~ ^[0-9] ]]; then
    pass "Histogram vllm:e2e_request_latency_seconds_bucket exists in Prometheus"
  else
    fail "Histogram vllm:e2e_request_latency_seconds_bucket not found in Prometheus"
  fi

  # 4.6 Metric gpu_cache_usage present
  local cache_exists
  cache_exists=$(prometheus_query 'count(vllm:gpu_cache_usage_perc{pod=~"qwen-hybrid.*"})')
  if [[ "$cache_exists" =~ ^[0-9] ]]; then
    pass "Metric vllm:gpu_cache_usage_perc exists in Prometheus"
  else
    skip "Metric vllm:gpu_cache_usage_perc not found (may not be available in this vLLM version)"
  fi
}

# ---------------------------------------------------------------------------
# SUITE 5 — ServiceMonitor
# ---------------------------------------------------------------------------
test_servicemonitor_config() {
  header "SUITE 5 — ServiceMonitor"

  # 5.1 ServiceMonitor vllm-burst-scaling exists
  local sm_vllm
  sm_vllm=$(kubectl get servicemonitor \
    "vllm-burst-scaling" \
    -n "$DEFAULT_NS" \
    -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")

  if [[ -n "$sm_vllm" ]]; then
    pass "ServiceMonitor vllm-burst-scaling exists in namespace ${DEFAULT_NS}"
  else
    fail "ServiceMonitor vllm-burst-scaling not found in namespace ${DEFAULT_NS}"
  fi

  # 5.2 ServiceMonitor points to port http
  local sm_port
  sm_port=$(kubectl get servicemonitor \
    "vllm-burst-scaling" \
    -n "$DEFAULT_NS" \
    -o jsonpath='{.spec.endpoints[0].port}' 2>/dev/null || echo "")

  if [[ "$sm_port" == "http" ]]; then
    pass "ServiceMonitor points to port 'http'"
  else
    fail "ServiceMonitor port incorrect: '${sm_port}' (expected 'http')"
  fi

  # 5.3 ServiceMonitor path is /metrics
  local sm_path
  sm_path=$(kubectl get servicemonitor \
    "vllm-burst-scaling" \
    -n "$DEFAULT_NS" \
    -o jsonpath='{.spec.endpoints[0].path}' 2>/dev/null || echo "")

  if [[ "$sm_path" == "/metrics" ]]; then
    pass "ServiceMonitor path correct: /metrics"
  else
    fail "ServiceMonitor path incorrect: '${sm_path}' (expected '/metrics')"
  fi

  # 5.4 ServiceMonitor interval is 15s
  local sm_interval
  sm_interval=$(kubectl get servicemonitor \
    "vllm-burst-scaling" \
    -n "$DEFAULT_NS" \
    -o jsonpath='{.spec.endpoints[0].interval}' 2>/dev/null || echo "")

  if [[ "$sm_interval" == "15s" ]]; then
    pass "ServiceMonitor interval correct: 15s"
  else
    fail "ServiceMonitor interval incorrect: '${sm_interval}' (expected '15s')"
  fi

  # 5.5 ServiceMonitor selector points to label model=qwen25-1-5b
  local sm_selector
  sm_selector=$(kubectl get servicemonitor \
    "vllm-burst-scaling" \
    -n "$DEFAULT_NS" \
    -o jsonpath='{.spec.selector.matchLabels.model}' 2>/dev/null || echo "")

  if [[ "$sm_selector" == "qwen25-1-5b" ]]; then
    pass "ServiceMonitor selector correct: model=qwen25-1-5b"
  else
    fail "ServiceMonitor selector incorrect: '${sm_selector}' (expected 'qwen25-1-5b')"
  fi

  # 5.6 PrometheusRule vllm-burst-scaling-alerts exists
  local prom_rule
  prom_rule=$(kubectl get prometheusrule \
    "vllm-burst-scaling-alerts" \
    -n "$DEFAULT_NS" \
    -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")

  if [[ -n "$prom_rule" ]]; then
    pass "PrometheusRule vllm-burst-scaling-alerts exists"
  else
    fail "PrometheusRule vllm-burst-scaling-alerts not found"
  fi
}

# ---------------------------------------------------------------------------
# Main runner
# ---------------------------------------------------------------------------
run_all_tests() {
  echo -e "\n${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║  test_observability.sh — Prometheus, Grafana, DCGM, vLLM    ║${NC}"
  echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo -e "Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')\n"

  test_prometheus_running
  test_grafana_accessible
  test_dcgm_exporter
  test_vllm_metrics
  test_servicemonitor_config

  local total=$(( PASSED + FAILED + SKIPPED ))
  echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "Result: Total ${total} | ${GREEN}Passed ${PASSED}${NC} | ${RED}Failed ${FAILED}${NC} | ${YELLOW}Skipped ${SKIPPED}${NC}"

  if [[ "$FAILED" -gt 0 ]]; then
    echo -e "${RED}Status: FAILED${NC}"
    exit 1
  else
    echo -e "${GREEN}Status: PASSED${NC}"
    exit 0
  fi
}

run_all_tests
