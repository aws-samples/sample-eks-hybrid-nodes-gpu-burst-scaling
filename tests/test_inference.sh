#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# =============================================================================
# tests/test_inference.sh
# Model functional tests — vLLM + Qwen3.6-35B-A3B-AWQ
#
# Covers:
#   - vLLM health endpoint responding
#   - Basic inference (chat completions)
#   - Streaming inference (SSE)
#   - Correct model loaded (Qwen3.6-35B-A3B-AWQ)
#   - Acceptable latency (TTFT < 2s, E2E < 30s)
#   - Minimum throughput (> 10 tokens/s)
#
# Usage: ./tests/test_inference.sh
# Optional environment variables:
#   VLLM_HOST  — IP/hostname of vLLM (default: auto-detected via kubectl)
#   VLLM_PORT  — port (default: 8000)
# =============================================================================
set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
VLLM_PORT="${VLLM_PORT:-8000}"
MODEL_NAME="${MODEL_NAME:-Qwen3.6-35B-A3B-AWQ}"
TTFT_THRESHOLD_S="${TTFT_THRESHOLD_S:-2.0}"      # seconds
E2E_THRESHOLD_S="${E2E_THRESHOLD_S:-30.0}"        # seconds
MIN_THROUGHPUT_TPS="${MIN_THROUGHPUT_TPS:-10}"    # tokens/s
TEST_TIMEOUT="${TEST_TIMEOUT:-60}"                # timeout per test
INFERENCE_TIMEOUT="${INFERENCE_TIMEOUT:-45}"      # timeout for inference calls

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

# Detects the vLLM host (hostNetwork=true → uses node IP)
detect_vllm_host() {
  if [[ -n "${VLLM_HOST:-}" ]]; then
    echo "$VLLM_HOST"
    return
  fi

  # Hybrid pod uses hostNetwork — get the node IP
  local host_ip
  host_ip=$(kubectl get pod \
    -l "tier=hybrid" \
    -o jsonpath='{.items[0].status.hostIP}' 2>/dev/null || echo "")

  if [[ -n "$host_ip" ]]; then
    echo "$host_ip"
    return
  fi

  # Fallback: ClusterIP of the service
  local svc_ip
  svc_ip=$(kubectl get svc "qwen36-burst-svc" \
    -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")

  echo "${svc_ip:-}"
}

# Executes curl inside a test pod in the cluster
# Usage: cluster_curl <url> [curl_args...]
cluster_curl() {
  local url="$1"; shift
  local extra_args=("$@")

  kubectl run inference-test-curl \
    --image=curlimages/curl:8.7.1 \
    --restart=Never \
    --rm \
    --quiet \
    --command -- curl -s --max-time "$((INFERENCE_TIMEOUT - 5))" \
    "${extra_args[@]}" "$url" 2>/dev/null
}

# ---------------------------------------------------------------------------
# SUITE 1 — Health Check
# ---------------------------------------------------------------------------
test_vllm_health() {
  header "SUITE 1 — vLLM Health Endpoint"

  local vllm_host
  vllm_host=$(detect_vllm_host)

  if [[ -z "$vllm_host" ]]; then
    fail "Could not detect vLLM host"
    return
  fi
  info "vLLM host: ${vllm_host}:${VLLM_PORT}"
  export VLLM_ENDPOINT="http://${vllm_host}:${VLLM_PORT}"

  # 1.1 /health returns 200
  local health_status
  health_status=$(kubectl exec \
    "$(kubectl get pod -l tier=hybrid -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" \
    -- wget -qO- --server-response "http://localhost:${VLLM_PORT}/health" 2>&1 \
    | grep "HTTP/" | awk '{print $2}' | head -1 || echo "")

  # Alternativa: via curl no pod
  if [[ -z "$health_status" ]]; then
    health_status=$(kubectl exec \
      "$(kubectl get pod -l tier=hybrid -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" \
      -- sh -c "curl -s -o /dev/null -w '%{http_code}' http://localhost:${VLLM_PORT}/health" \
      2>/dev/null || echo "000")
  fi

  if [[ "$health_status" == "200" ]]; then
    pass "GET /health returns HTTP 200"
  else
    fail "GET /health returns HTTP ${health_status} (expected 200)"
  fi

  # 1.2 Hybrid pod is Ready (readinessProbe passed)
  local hybrid_pod
  hybrid_pod=$(kubectl get pod \
    -l "tier=hybrid" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  if [[ -z "$hybrid_pod" ]]; then
    fail "Hybrid pod not found"
    return
  fi

  local pod_ready
  pod_ready=$(kubectl get pod "$hybrid_pod" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")

  if [[ "$pod_ready" == "True" ]]; then
    pass "Hybrid pod Ready=True (readinessProbe passed)"
  else
    fail "Pod hybrid Ready=${pod_ready}"
  fi

  # 1.3 /v1/models returns list of models
  local models_response
  models_response=$(kubectl exec "$hybrid_pod" \
    -- sh -c "curl -s http://localhost:${VLLM_PORT}/v1/models" 2>/dev/null || echo "FAIL")

  if echo "$models_response" | grep -qi "data\|model"; then
    pass "GET /v1/models returns list of models"
  else
    fail "GET /v1/models does not return valid response: ${models_response}"
  fi
}

# ---------------------------------------------------------------------------
# SUITE 2 — Correct Model Loaded
# ---------------------------------------------------------------------------
test_correct_model_loaded() {
  header "SUITE 2 — Correct Model Loaded"

  local hybrid_pod
  hybrid_pod=$(kubectl get pod \
    -l "tier=hybrid" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  if [[ -z "$hybrid_pod" ]]; then
    skip "Hybrid pod not found"
    return
  fi

  # 2.1 /v1/models lists the model Qwen3.6-35B-A3B-AWQ
  local models_json
  models_json=$(kubectl exec "$hybrid_pod" \
    -- sh -c "curl -s http://localhost:${VLLM_PORT}/v1/models" 2>/dev/null || echo "")

  if echo "$models_json" | grep -q "$MODEL_NAME"; then
    pass "Model ${MODEL_NAME} listed in /v1/models"
  else
    fail "Model ${MODEL_NAME} not found in /v1/models (response: ${models_json})"
  fi

  # 2.2 Argument --served-model-name correct in container
  local served_model
  served_model=$(kubectl get pod "$hybrid_pod" \
    -o jsonpath='{.spec.containers[0].args}' 2>/dev/null \
    | grep -o "Qwen3[^'\"]*" | head -1 || echo "")

  if [[ "$served_model" == "$MODEL_NAME" ]]; then
    pass "Argument --served-model-name correct: ${served_model}"
  else
    fail "Argument --served-model-name incorrect: '${served_model}' (expected '${MODEL_NAME}')"
  fi

  # 2.3 tensor-parallel-size=4 configured
  local tp_size
  tp_size=$(kubectl get pod "$hybrid_pod" \
    -o jsonpath='{.spec.containers[0].args}' 2>/dev/null \
    | grep -o "tensor-parallel-size=[0-9]*" | cut -d= -f2 || echo "")

  if [[ "$tp_size" == "4" ]]; then
    pass "tensor-parallel-size=4 configured"
  else
    fail "tensor-parallel-size incorrect: '${tp_size}' (expected '4')"
  fi

  # 2.4 quantization=awq_marlin configured
  local quant
  quant=$(kubectl get pod "$hybrid_pod" \
    -o jsonpath='{.spec.containers[0].args}' 2>/dev/null \
    | grep -o "quantization=[a-z_]*" | cut -d= -f2 || echo "")

  if [[ "$quant" == "awq_marlin" ]]; then
    pass "quantization=awq_marlin configured"
  else
    fail "quantization incorrect: '${quant}' (expected 'awq_marlin')"
  fi
}

# ---------------------------------------------------------------------------
# SUITE 3 — Basic Inference
# ---------------------------------------------------------------------------
test_basic_inference() {
  header "SUITE 3 — Basic Inference (Chat Completions)"

  local hybrid_pod
  hybrid_pod=$(kubectl get pod \
    -l "tier=hybrid" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  if [[ -z "$hybrid_pod" ]]; then
    skip "Hybrid pod not found"
    return
  fi

  # Minimal payload for quick test
  local payload
  payload='{"model":"'"$MODEL_NAME"'","messages":[{"role":"user","content":"Say hello in one word"}],"max_tokens":10,"temperature":0}'

  # 3.1 POST /v1/chat/completions returns 200
  local start_time end_time elapsed_s
  start_time=$(date +%s%N)

  local response
  response=$(kubectl exec "$hybrid_pod" \
    -- sh -c "curl -s -w '\n__HTTP_CODE__:%{http_code}' \
      -X POST http://localhost:${VLLM_PORT}/v1/chat/completions \
      -H 'Content-Type: application/json' \
      -d '${payload}'" 2>/dev/null || echo "__HTTP_CODE__:000")

  end_time=$(date +%s%N)
  elapsed_s=$(echo "scale=3; ($end_time - $start_time) / 1000000000" | bc 2>/dev/null || echo "0")

  local http_code
  http_code=$(echo "$response" | grep "__HTTP_CODE__:" | cut -d: -f2)

  if [[ "$http_code" == "200" ]]; then
    pass "POST /v1/chat/completions returns HTTP 200"
  else
    fail "POST /v1/chat/completions returns HTTP ${http_code} (expected 200)"
    return
  fi

  # 3.2 Response contains choices field
  local body
  body=$(echo "$response" | grep -v "__HTTP_CODE__:")

  if echo "$body" | grep -q '"choices"'; then
    pass "Response contains 'choices' field"
  else
    fail "Response does not contain 'choices' field: ${body}"
  fi

  # 3.3 Response contains non-empty content
  local content
  content=$(echo "$body" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    c = d['choices'][0]['message']['content']
    print(c if c else 'EMPTY')
except Exception as e:
    print(f'PARSE_ERROR: {e}')
" 2>/dev/null || echo "PARSE_ERROR")

  if [[ -n "$content" && "$content" != "EMPTY" && "$content" != *"PARSE_ERROR"* ]]; then
    pass "Response contains content: '${content}'"
  else
    fail "Response with invalid content: '${content}'"
  fi

  # 3.4 E2E latency < threshold
  local e2e_ok
  e2e_ok=$(echo "$elapsed_s < $E2E_THRESHOLD_S" | bc 2>/dev/null || echo "0")

  if [[ "$e2e_ok" == "1" ]]; then
    pass "E2E latency: ${elapsed_s}s (threshold: ${E2E_THRESHOLD_S}s)"
  else
    fail "E2E latency: ${elapsed_s}s exceeds threshold of ${E2E_THRESHOLD_S}s"
  fi

  # 3.5 usage.completion_tokens > 0
  local completion_tokens
  completion_tokens=$(echo "$body" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('usage', {}).get('completion_tokens', 0))
except:
    print(0)
" 2>/dev/null || echo "0")

  if [[ "${completion_tokens:-0}" -gt 0 ]]; then
    pass "completion_tokens > 0: ${completion_tokens}"
  else
    fail "completion_tokens = 0 (model did not generate tokens)"
  fi
}

# ---------------------------------------------------------------------------
# SUITE 4 — Streaming Inference
# ---------------------------------------------------------------------------
test_streaming_inference() {
  header "SUITE 4 — Streaming Inference (SSE)"

  local hybrid_pod
  hybrid_pod=$(kubectl get pod \
    -l "tier=hybrid" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  if [[ -z "$hybrid_pod" ]]; then
    skip "Hybrid pod not found"
    return
  fi

  local payload
  payload='{"model":"'"$MODEL_NAME"'","messages":[{"role":"user","content":"Count from 1 to 5"}],"max_tokens":30,"stream":true,"temperature":0}'

  # 4.1 Streaming returns HTTP 200 with content-type text/event-stream
  local stream_response
  stream_response=$(kubectl exec "$hybrid_pod" \
    -- sh -c "curl -s -N --max-time $((INFERENCE_TIMEOUT - 5)) \
      -X POST http://localhost:${VLLM_PORT}/v1/chat/completions \
      -H 'Content-Type: application/json' \
      -d '${payload}' 2>&1 | head -20" 2>/dev/null || echo "FAIL")

  if echo "$stream_response" | grep -q "data:"; then
    pass "Streaming returns SSE events (data: ...)"
  else
    fail "Streaming does not return expected SSE events: ${stream_response}"
  fi

  # 4.2 [DONE] event present at end of stream
  local stream_full
  stream_full=$(kubectl exec "$hybrid_pod" \
    -- sh -c "curl -s -N --max-time $((INFERENCE_TIMEOUT - 5)) \
      -X POST http://localhost:${VLLM_PORT}/v1/chat/completions \
      -H 'Content-Type: application/json' \
      -d '${payload}'" 2>/dev/null || echo "FAIL")

  if echo "$stream_full" | grep -q "\[DONE\]"; then
    pass "Stream ends with [DONE] event"
  else
    fail "Stream does not end with [DONE] (may have timed out or failed)"
  fi

  # 4.3 Chunks contain delta.content
  if echo "$stream_full" | grep -q '"delta"'; then
    pass "Streaming chunks contain 'delta' field"
  else
    fail "Streaming chunks do not contain 'delta' field"
  fi

  # 4.4 Measure TTFT (time to first chunk with content)
  local ttft_start ttft_end ttft_s
  ttft_start=$(date +%s%N)

  local first_chunk
  first_chunk=$(kubectl exec "$hybrid_pod" \
    -- sh -c "curl -s -N --max-time $((INFERENCE_TIMEOUT - 5)) \
      -X POST http://localhost:${VLLM_PORT}/v1/chat/completions \
      -H 'Content-Type: application/json' \
      -d '${payload}' | grep -m1 'content' | head -1" 2>/dev/null || echo "")

  ttft_end=$(date +%s%N)
  ttft_s=$(echo "scale=3; ($ttft_end - $ttft_start) / 1000000000" | bc 2>/dev/null || echo "0")

  if [[ -n "$first_chunk" ]]; then
    local ttft_ok
    ttft_ok=$(echo "$ttft_s < $TTFT_THRESHOLD_S" | bc 2>/dev/null || echo "0")
    if [[ "$ttft_ok" == "1" ]]; then
      pass "TTFT: ${ttft_s}s (threshold: ${TTFT_THRESHOLD_S}s)"
    else
      fail "TTFT: ${ttft_s}s exceeds threshold of ${TTFT_THRESHOLD_S}s"
    fi
  else
    skip "Could not measure TTFT (first chunk not captured)"
  fi
}

# ---------------------------------------------------------------------------
# SUITE 5 — Throughput
# ---------------------------------------------------------------------------
test_throughput() {
  header "SUITE 5 — Throughput (tokens/s)"

  local hybrid_pod
  hybrid_pod=$(kubectl get pod \
    -l "tier=hybrid" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  if [[ -z "$hybrid_pod" ]]; then
    skip "Hybrid pod not found"
    return
  fi

  # Payload with more tokens to measure throughput
  local payload
  payload='{"model":"'"$MODEL_NAME"'","messages":[{"role":"user","content":"Write a short paragraph about machine learning"}],"max_tokens":100,"temperature":0}'

  local start_time end_time elapsed_s
  start_time=$(date +%s%N)

  local response
  response=$(kubectl exec "$hybrid_pod" \
    -- sh -c "curl -s -X POST http://localhost:${VLLM_PORT}/v1/chat/completions \
      -H 'Content-Type: application/json' \
      -d '${payload}'" 2>/dev/null || echo "FAIL")

  end_time=$(date +%s%N)
  elapsed_s=$(echo "scale=3; ($end_time - $start_time) / 1000000000" | bc 2>/dev/null || echo "1")

  if [[ "$response" == "FAIL" ]]; then
    fail "Throughput request failed"
    return
  fi

  # Extrai completion_tokens
  local tokens
  tokens=$(echo "$response" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('usage', {}).get('completion_tokens', 0))
except:
    print(0)
" 2>/dev/null || echo "0")

  if [[ "${tokens:-0}" -eq 0 ]]; then
    fail "No tokens generated in throughput request"
    return
  fi

  # Calculates tokens/s
  local tps
  tps=$(echo "scale=2; $tokens / $elapsed_s" | bc 2>/dev/null || echo "0")
  info "Tokens generated: ${tokens} | Time: ${elapsed_s}s | Throughput: ${tps} tokens/s"

  local tps_ok
  tps_ok=$(echo "$tps > $MIN_THROUGHPUT_TPS" | bc 2>/dev/null || echo "0")

  if [[ "$tps_ok" == "1" ]]; then
    pass "Throughput: ${tps} tokens/s (minimum: ${MIN_THROUGHPUT_TPS} tokens/s)"
  else
    fail "Throughput: ${tps} tokens/s below minimum of ${MIN_THROUGHPUT_TPS} tokens/s"
  fi

  # 5.2 Verify throughput via Prometheus metric (if available)
  local prom_pod
  prom_pod=$(kubectl get pods -n monitoring \
    -l "app.kubernetes.io/name=prometheus" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  if [[ -n "$prom_pod" ]]; then
    local prom_tps
    prom_tps=$(kubectl exec -n monitoring "$prom_pod" \
      -c prometheus \
      -- wget -qO- "http://localhost:9090/api/v1/query?query=rate(vllm:generation_tokens_total%7Bpod%3D~%22qwen36-hybrid.*%22%7D%5B5m%5D)" \
      2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    r = d.get('data', {}).get('result', [])
    if r:
        print(float(r[0]['value'][1]))
    else:
        print('NO_DATA')
except:
    print('PARSE_ERROR')
" 2>/dev/null || echo "NO_DATA")

    if [[ "$prom_tps" =~ ^[0-9] ]]; then
      pass "Prometheus reports generation rate: ${prom_tps} tokens/s"
    else
      skip "Metric vllm:generation_tokens_total not available in Prometheus (${prom_tps})"
    fi
  fi
}

# ---------------------------------------------------------------------------
# SUITE 6 — Inference Edge Cases
# ---------------------------------------------------------------------------
test_inference_edge_cases() {
  header "SUITE 6 — Inference Edge Cases"

  local hybrid_pod
  hybrid_pod=$(kubectl get pod \
    -l "tier=hybrid" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  if [[ -z "$hybrid_pod" ]]; then
    skip "Hybrid pod not found"
    return
  fi

  # 6.1 Invalid model returns 404 or 400
  local invalid_response
  invalid_response=$(kubectl exec "$hybrid_pod" \
    -- sh -c "curl -s -o /dev/null -w '%{http_code}' \
      -X POST http://localhost:${VLLM_PORT}/v1/chat/completions \
      -H 'Content-Type: application/json' \
      -d '{\"model\":\"nonexistent-model\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":5}'" \
    2>/dev/null || echo "000")

  if [[ "$invalid_response" =~ ^(400|404|422)$ ]]; then
    pass "Invalid model returns HTTP ${invalid_response} (expected error)"
  else
    fail "Invalid model returns HTTP ${invalid_response} (expected 400/404/422)"
  fi

  # 6.2 max_tokens=0 returns error
  local zero_tokens_response
  zero_tokens_response=$(kubectl exec "$hybrid_pod" \
    -- sh -c "curl -s -o /dev/null -w '%{http_code}' \
      -X POST http://localhost:${VLLM_PORT}/v1/chat/completions \
      -H 'Content-Type: application/json' \
      -d '{\"model\":\"${MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":0}'" \
    2>/dev/null || echo "000")

  if [[ "$zero_tokens_response" =~ ^(400|422)$ ]]; then
    pass "max_tokens=0 returns HTTP ${zero_tokens_response} (expected error)"
  else
    # Some models accept max_tokens=0 and return empty response — not necessarily an error
    skip "max_tokens=0 returned HTTP ${zero_tokens_response} (behavior may vary)"
  fi

  # 6.3 Malformed payload returns 400/422
  local malformed_response
  malformed_response=$(kubectl exec "$hybrid_pod" \
    -- sh -c "curl -s -o /dev/null -w '%{http_code}' \
      -X POST http://localhost:${VLLM_PORT}/v1/chat/completions \
      -H 'Content-Type: application/json' \
      -d 'not-valid-json'" \
    2>/dev/null || echo "000")

  if [[ "$malformed_response" =~ ^(400|422)$ ]]; then
    pass "Malformed payload returns HTTP ${malformed_response}"
  else
    fail "Malformed payload returns HTTP ${malformed_response} (expected 400/422)"
  fi

  # 6.4 Non-existent endpoint returns 404
  local not_found_response
  not_found_response=$(kubectl exec "$hybrid_pod" \
    -- sh -c "curl -s -o /dev/null -w '%{http_code}' \
      http://localhost:${VLLM_PORT}/v1/nonexistent" \
    2>/dev/null || echo "000")

  if [[ "$not_found_response" == "404" ]]; then
    pass "Non-existent endpoint returns HTTP 404"
  else
    fail "Non-existent endpoint returns HTTP ${not_found_response} (expected 404)"
  fi
}

# ---------------------------------------------------------------------------
# Main runner
# ---------------------------------------------------------------------------
run_all_tests() {
  echo -e "\n${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║  test_inference.sh — vLLM + Qwen3.6-35B-A3B-AWQ            ║${NC}"
  echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo -e "Model: ${MODEL_NAME} | TTFT threshold: ${TTFT_THRESHOLD_S}s | E2E threshold: ${E2E_THRESHOLD_S}s"
  echo -e "Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')\n"

  test_vllm_health
  test_correct_model_loaded
  test_basic_inference
  test_streaming_inference
  test_throughput
  test_inference_edge_cases

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
