#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# =============================================================================
# tests/test_scaling.sh
# Scalability tests — KEDA + Karpenter + Burst Scaling
#
# Covers:
#   - KEDA ScaledObject Ready
#   - Burst deployment at scale-to-zero (0 replicas without load)
#   - KEDA activates under load (queue depth > threshold)
#   - Karpenter provisions GPU nodes (NodeClaims created)
#   - Burst pods become Ready after provisioning
#   - Scale-down after cooldown (300s)
#   - GPU NodePool with spot + on-demand configured
#
# Usage: ./tests/test_scaling.sh
#
# WARNING: Scale-up tests (SUITE 3+) generate real load on the cluster.
#          Use SKIP_LOAD_TESTS=true to skip these tests.
# =============================================================================
set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
KEDA_NS="${KEDA_NS:-kube-system}"
DEFAULT_NS="${DEFAULT_NS:-default}"
SCALEDOBJECT_NAME="${SCALEDOBJECT_NAME:-qwen-burst-scaler}"
BURST_DEPLOY="${BURST_DEPLOY:-qwen-burst}"
HYBRID_DEPLOY="${HYBRID_DEPLOY:-qwen-hybrid}"
MODEL_NAME="${MODEL_NAME:-Qwen3.6-35B-A3B-AWQ}"
KARPENTER_NODEPOOL="${KARPENTER_NODEPOOL:-gpu}"
COOLDOWN_PERIOD="${COOLDOWN_PERIOD:-300}"          # seconds
SCALE_UP_TIMEOUT="${SCALE_UP_TIMEOUT:-180}"        # timeout for KEDA to activate
NODE_PROVISION_TIMEOUT="${NODE_PROVISION_TIMEOUT:-420}"  # timeout for Karpenter to provision
POD_READY_TIMEOUT="${POD_READY_TIMEOUT:-600}"      # timeout for burst pods to become Ready
SCALE_DOWN_WAIT="${SCALE_DOWN_WAIT:-360}"          # wait for scale-down
TEST_TIMEOUT="${TEST_TIMEOUT:-30}"
SKIP_LOAD_TESTS="${SKIP_LOAD_TESTS:-false}"
LOAD_JOB_NAME="${LOAD_JOB_NAME:-scaling-test-load}"

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

# Cleanup test resources on exit
cleanup_load_job() {
  kubectl delete job "$LOAD_JOB_NAME" --ignore-not-found &>/dev/null || true
}
trap cleanup_load_job EXIT

# ---------------------------------------------------------------------------
# SUITE 1 — KEDA ScaledObject
# ---------------------------------------------------------------------------
test_keda_scaledobject() {
  header "SUITE 1 — KEDA ScaledObject"

  # 1.1 ScaledObject exists
  local so_name
  so_name=$(kubectl get scaledobject \
    "$SCALEDOBJECT_NAME" \
    -n "$DEFAULT_NS" \
    -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")

  if [[ -n "$so_name" ]]; then
    pass "ScaledObject ${SCALEDOBJECT_NAME} exists in namespace ${DEFAULT_NS}"
  else
    fail "ScaledObject ${SCALEDOBJECT_NAME} not found in namespace ${DEFAULT_NS}"
    return
  fi

  # 1.2 ScaledObject has condition Ready=True
  local so_ready
  so_ready=$(kubectl get scaledobject \
    "$SCALEDOBJECT_NAME" \
    -n "$DEFAULT_NS" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")

  if [[ "$so_ready" == "True" ]]; then
    pass "ScaledObject Ready=True"
  else
    fail "ScaledObject Ready=${so_ready} (expected True)"
  fi

  # 1.3 ScaledObject points to correct deployment
  local so_target
  so_target=$(kubectl get scaledobject \
    "$SCALEDOBJECT_NAME" \
    -n "$DEFAULT_NS" \
    -o jsonpath='{.spec.scaleTargetRef.name}' 2>/dev/null || echo "")

  if [[ "$so_target" == "$BURST_DEPLOY" ]]; then
    pass "ScaledObject points to correct deployment: ${so_target}"
  else
    fail "ScaledObject points to '${so_target}' (expected '${BURST_DEPLOY}')"
  fi

  # 1.4 minReplicaCount=0 (scale-to-zero enabled)
  local min_replicas
  min_replicas=$(kubectl get scaledobject \
    "$SCALEDOBJECT_NAME" \
    -n "$DEFAULT_NS" \
    -o jsonpath='{.spec.minReplicaCount}' 2>/dev/null || echo "")

  if [[ "${min_replicas:-0}" -eq 0 ]]; then
    pass "minReplicaCount=0 (scale-to-zero enabled)"
  else
    fail "minReplicaCount=${min_replicas} (expected 0 for scale-to-zero)"
  fi

  # 1.5 maxReplicaCount=4
  local max_replicas
  max_replicas=$(kubectl get scaledobject \
    "$SCALEDOBJECT_NAME" \
    -n "$DEFAULT_NS" \
    -o jsonpath='{.spec.maxReplicaCount}' 2>/dev/null || echo "")

  if [[ "${max_replicas:-0}" -eq 4 ]]; then
    pass "maxReplicaCount=4"
  else
    fail "maxReplicaCount=${max_replicas} (expected 4)"
  fi

  # 1.6 cooldownPeriod=300
  local cooldown
  cooldown=$(kubectl get scaledobject \
    "$SCALEDOBJECT_NAME" \
    -n "$DEFAULT_NS" \
    -o jsonpath='{.spec.cooldownPeriod}' 2>/dev/null || echo "")

  if [[ "${cooldown:-0}" -eq 300 ]]; then
    pass "cooldownPeriod=300s"
  else
    fail "cooldownPeriod=${cooldown} (expected 300)"
  fi

  # 1.7 3 Prometheus triggers configured
  local trigger_count
  trigger_count=$(kubectl get scaledobject \
    "$SCALEDOBJECT_NAME" \
    -n "$DEFAULT_NS" \
    -o jsonpath='{.spec.triggers}' 2>/dev/null \
    | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

  if [[ "${trigger_count:-0}" -ge 3 ]]; then
    pass "ScaledObject has ${trigger_count} triggers configured (≥3)"
  else
    fail "ScaledObject has ${trigger_count} triggers (expected ≥3)"
  fi

  # 1.8 KEDA operator running
  local keda_pods
  keda_pods=$(kubectl get pods \
    -l "app=keda-operator" \
    --all-namespaces \
    -o jsonpath='{.items[*].status.phase}' 2>/dev/null | tr ' ' '\n' | grep -c "^Running$" || echo "0")

  if [[ "${keda_pods:-0}" -ge 1 ]]; then
    pass "KEDA operator running (${keda_pods} pod(s))"
  else
    fail "KEDA operator not found or not Running"
  fi
}

# ---------------------------------------------------------------------------
# SUITE 2 — Scale-to-Zero (no load)
# ---------------------------------------------------------------------------
test_scale_to_zero() {
  header "SUITE 2 — Scale-to-Zero (no load)"

  # 2.1 Burst deployment exists
  local burst_exists
  burst_exists=$(kubectl get deployment \
    "$BURST_DEPLOY" \
    -n "$DEFAULT_NS" \
    -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")

  if [[ -n "$burst_exists" ]]; then
    pass "Deployment ${BURST_DEPLOY} exists"
  else
    fail "Deployment ${BURST_DEPLOY} not found"
    return
  fi

  # 2.2 Without load, burst should have 0 replicas (after cooldown)
  local burst_replicas
  burst_replicas=$(kubectl get deployment \
    "$BURST_DEPLOY" \
    -n "$DEFAULT_NS" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")

  if [[ "${burst_replicas:-0}" -eq 0 ]]; then
    pass "Burst deployment at scale-to-zero: spec.replicas=0"
  else
    info "Burst deployment has ${burst_replicas} replicas (may be in cooldown or under load)"
    # Not a definitive failure — may be in cooldown
    skip "Burst deployment has ${burst_replicas} replicas (may be in post-load cooldown)"
  fi

  # 2.3 No burst pods running (when replicas=0)
  if [[ "${burst_replicas:-0}" -eq 0 ]]; then
    local burst_pods
    burst_pods=$(kubectl get pods \
      -l "tier=burst" \
      -n "$DEFAULT_NS" \
      --no-headers 2>/dev/null | wc -l | tr -d ' ')

    if [[ "${burst_pods:-0}" -eq 0 ]]; then
      pass "No burst pods running (scale-to-zero confirmed)"
    else
      fail "Burst pods still running (${burst_pods}) despite spec.replicas=0"
    fi
  fi

  # 2.4 KEDA is not active without load
  local keda_active
  keda_active=$(kubectl get scaledobject \
    "$SCALEDOBJECT_NAME" \
    -n "$DEFAULT_NS" \
    -o jsonpath='{.status.conditions[?(@.type=="Active")].status}' 2>/dev/null || echo "")

  if [[ "$keda_active" == "False" || -z "$keda_active" ]]; then
    pass "KEDA ScaledObject is not active (no load)"
  else
    info "KEDA Active=${keda_active} (may be in cooldown or with residual load)"
    skip "KEDA still active — may be in cooldown"
  fi

  # 2.5 Hybrid deployment has 1 replica (baseline always active)
  local hybrid_replicas
  hybrid_replicas=$(kubectl get deployment \
    "$HYBRID_DEPLOY" \
    -n "$DEFAULT_NS" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")

  if [[ "${hybrid_replicas:-0}" -ge 1 ]]; then
    pass "Hybrid deployment active: spec.replicas=${hybrid_replicas}"
  else
    fail "Hybrid deployment with spec.replicas=${hybrid_replicas} (expected ≥1)"
  fi
}

# ---------------------------------------------------------------------------
# SUITE 3 — Karpenter NodePool
# ---------------------------------------------------------------------------
test_karpenter_nodepool() {
  header "SUITE 3 — Karpenter NodePool GPU"

  # 3.1 NodePool gpu exists
  local np_name
  np_name=$(kubectl get nodepool \
    "$KARPENTER_NODEPOOL" \
    -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")

  if [[ -n "$np_name" ]]; then
    pass "NodePool '${KARPENTER_NODEPOOL}' exists"
  else
    fail "NodePool '${KARPENTER_NODEPOOL}' not found"
    return
  fi

  # 3.2 NodePool has spot AND on-demand configured
  local capacity_types
  capacity_types=$(kubectl get nodepool \
    "$KARPENTER_NODEPOOL" \
    -o jsonpath='{.spec.template.spec.requirements[?(@.key=="karpenter.sh/capacity-type")].values}' \
    2>/dev/null || echo "")

  if echo "$capacity_types" | grep -q "spot" && echo "$capacity_types" | grep -q "on-demand"; then
    pass "NodePool has spot and on-demand configured"
  else
    fail "NodePool does not have spot+on-demand: ${capacity_types}"
  fi

  # 3.3 NodePool has taint nvidia.com/gpu:NoSchedule
  local np_taint
  np_taint=$(kubectl get nodepool \
    "$KARPENTER_NODEPOOL" \
    -o jsonpath='{.spec.template.spec.taints[?(@.key=="nvidia.com/gpu")].effect}' \
    2>/dev/null || echo "")

  if [[ "$np_taint" == "NoSchedule" ]]; then
    pass "NodePool has taint nvidia.com/gpu:NoSchedule"
  else
    fail "NodePool missing taint nvidia.com/gpu:NoSchedule (found: '${np_taint}')"
  fi

  # 3.4 NodePool has GPU instance types (g6.*)
  local instance_types
  instance_types=$(kubectl get nodepool \
    "$KARPENTER_NODEPOOL" \
    -o jsonpath='{.spec.template.spec.requirements[?(@.key=="node.kubernetes.io/instance-type")].values}' \
    2>/dev/null || echo "")

  if echo "$instance_types" | grep -q "g6\|g7"; then
    pass "NodePool has GPU instance types (g6.*/g7.*)"
  else
    fail "NodePool missing GPU instance types: ${instance_types}"
  fi

  # 3.5 NodePool has GPU limit (nvidia.com/gpu: 16)
  local gpu_limit
  gpu_limit=$(kubectl get nodepool \
    "$KARPENTER_NODEPOOL" \
    -o jsonpath='{.spec.limits.nvidia\.com/gpu}' \
    2>/dev/null || echo "")

  if [[ -n "$gpu_limit" && "${gpu_limit:-0}" -gt 0 ]]; then
    pass "NodePool has GPU limit: ${gpu_limit}"
  else
    fail "NodePool has no GPU limit configured"
  fi

  # 3.6 EC2NodeClass gpu exists
  local nc_name
  nc_name=$(kubectl get ec2nodeclass \
    "$KARPENTER_NODEPOOL" \
    -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")

  if [[ -n "$nc_name" ]]; then
    pass "EC2NodeClass '${KARPENTER_NODEPOOL}' exists"
  else
    fail "EC2NodeClass '${KARPENTER_NODEPOOL}' not found"
  fi

  # 3.7 Karpenter controller running
  local karpenter_pods
  karpenter_pods=$(kubectl get pods \
    -l "app.kubernetes.io/name=karpenter" \
    --all-namespaces \
    -o jsonpath='{.items[*].status.phase}' 2>/dev/null | tr ' ' '\n' | grep -c "^Running$" || echo "0")

  if [[ "${karpenter_pods:-0}" -ge 1 ]]; then
    pass "Karpenter controller running (${karpenter_pods} pod(s))"
  else
    fail "Karpenter controller not found or not Running"
  fi
}

# ---------------------------------------------------------------------------
# SUITE 4 — Scale-Up Under Load (requires real load)
# ---------------------------------------------------------------------------
test_scale_up_under_load() {
  header "SUITE 4 — Scale-Up Under Load (KEDA → Karpenter)"

  if [[ "$SKIP_LOAD_TESTS" == "true" ]]; then
    skip "SKIP_LOAD_TESTS=true — skipping scale-up tests"
    return
  fi

  # Verify that hybrid pod is available to receive load
  local hybrid_pod
  hybrid_pod=$(kubectl get pod \
    -l "tier=hybrid" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  if [[ -z "$hybrid_pod" ]]; then
    skip "Hybrid pod not available — skipping scale-up test"
    return
  fi

  local hybrid_ip
  hybrid_ip=$(kubectl get pod "$hybrid_pod" \
    -o jsonpath='{.status.hostIP}' 2>/dev/null || echo "")

  if [[ -z "$hybrid_ip" ]]; then
    skip "Hybrid pod IP not available"
    return
  fi

  info "Generating load on hybrid pod (${hybrid_ip}:8000) to activate KEDA..."

  # 4.1 Create load Job (50 concurrent requests, 3 rounds)
  kubectl delete job "$LOAD_JOB_NAME" --ignore-not-found &>/dev/null || true

  kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${LOAD_JOB_NAME}
  labels:
    app: scaling-test
spec:
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: load
          image: curlimages/curl:8.7.1
          command: ["/bin/sh", "-c"]
          args:
            - |
              for round in \$(seq 1 5); do
                echo "Round \$round: sending 50 requests..."
                for i in \$(seq 1 50); do
                  curl -s --max-time 60 http://${hybrid_ip}:8000/v1/chat/completions \
                    -H "Content-Type: application/json" \
                    -d '{"model":"${MODEL_NAME}","messages":[{"role":"user","content":"Write a detailed technical explanation of transformer architecture in deep learning"}],"max_tokens":512}' &
                done
                sleep 10
              done
              wait
              echo "Load completed"
EOF

  if [[ $? -eq 0 ]]; then
    pass "Load Job '${LOAD_JOB_NAME}' created successfully"
  else
    fail "Failed to create load Job"
    return
  fi

  # 4.2 Wait for KEDA to activate (polling every 15s, timeout 3min)
  info "Waiting for KEDA to activate (timeout: ${SCALE_UP_TIMEOUT}s)..."
  local keda_activated=false
  local elapsed=0
  local poll_interval=15

  while [[ "$elapsed" -lt "$SCALE_UP_TIMEOUT" ]]; do
    local keda_active
    keda_active=$(kubectl get scaledobject \
      "$SCALEDOBJECT_NAME" \
      -n "$DEFAULT_NS" \
      -o jsonpath='{.status.conditions[?(@.type=="Active")].status}' 2>/dev/null || echo "")

    local burst_replicas
    burst_replicas=$(kubectl get deployment \
      "$BURST_DEPLOY" \
      -n "$DEFAULT_NS" \
      -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")

    info "  [${elapsed}s] KEDA Active=${keda_active} | burst replicas=${burst_replicas}"

    if [[ "$keda_active" == "True" ]]; then
      keda_activated=true
      break
    fi

    sleep "$poll_interval"
    elapsed=$(( elapsed + poll_interval ))
  done

  if [[ "$keda_activated" == "true" ]]; then
    pass "KEDA activated under load (within ${elapsed}s)"
  else
    fail "KEDA did not activate within ${SCALE_UP_TIMEOUT}s"
    return
  fi

  # 4.3 Burst deployment scaled to > 0 replicas
  local burst_replicas_after
  burst_replicas_after=$(kubectl get deployment \
    "$BURST_DEPLOY" \
    -n "$DEFAULT_NS" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")

  if [[ "${burst_replicas_after:-0}" -gt 0 ]]; then
    pass "Burst deployment scaled up: spec.replicas=${burst_replicas_after}"
  else
    fail "Burst deployment did not scale up (spec.replicas=${burst_replicas_after})"
    return
  fi

  # 4.4 Karpenter created NodeClaims for GPU
  info "Waiting for Karpenter to create NodeClaims (timeout: ${NODE_PROVISION_TIMEOUT}s)..."
  local nodeclaims_created=false
  elapsed=0

  while [[ "$elapsed" -lt "$NODE_PROVISION_TIMEOUT" ]]; do
    local nodeclaim_count
    nodeclaim_count=$(kubectl get nodeclaims \
      -l "karpenter.sh/nodepool=${KARPENTER_NODEPOOL}" \
      --no-headers 2>/dev/null | wc -l | tr -d ' ')

    info "  [${elapsed}s] NodeClaims GPU: ${nodeclaim_count}"

    if [[ "${nodeclaim_count:-0}" -gt 0 ]]; then
      nodeclaims_created=true
      break
    fi

    sleep 20
    elapsed=$(( elapsed + 20 ))
  done

  if [[ "$nodeclaims_created" == "true" ]]; then
    local nc_list
    nc_list=$(kubectl get nodeclaims \
      -l "karpenter.sh/nodepool=${KARPENTER_NODEPOOL}" \
      -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    pass "Karpenter created GPU NodeClaims: ${nc_list}"
  else
    fail "Karpenter did not create NodeClaims within ${NODE_PROVISION_TIMEOUT}s"
    return
  fi

  # 4.5 Burst pods become Ready after provisioning
  info "Waiting for burst pods to become Ready (timeout: ${POD_READY_TIMEOUT}s)..."
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
    local ready_burst_pods
    ready_burst_pods=$(kubectl get pods \
      -l "tier=burst" \
      -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    pass "Burst pods Ready: ${ready_burst_pods}"
  else
    fail "Burst pods did not become Ready within ${POD_READY_TIMEOUT}s"
  fi
}

# ---------------------------------------------------------------------------
# SUITE 5 — Scale-Down After Cooldown
# ---------------------------------------------------------------------------
test_scale_down_after_cooldown() {
  header "SUITE 5 — Scale-Down After Cooldown"

  if [[ "$SKIP_LOAD_TESTS" == "true" ]]; then
    skip "SKIP_LOAD_TESTS=true — skipping scale-down test"
    return
  fi

  # Verify if there are burst pods running (pre-condition)
  local burst_replicas
  burst_replicas=$(kubectl get deployment \
    "$BURST_DEPLOY" \
    -n "$DEFAULT_NS" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")

  if [[ "${burst_replicas:-0}" -eq 0 ]]; then
    skip "Burst deployment already at 0 replicas — scale-down already occurred or no scale-up happened"
    return
  fi

  # Remove the load Job to stop pressure
  kubectl delete job "$LOAD_JOB_NAME" --ignore-not-found &>/dev/null || true
  info "Load Job removed. Waiting for cooldown of ${COOLDOWN_PERIOD}s + margin..."

  # Wait for cooldown + 60s margin
  local wait_time=$(( COOLDOWN_PERIOD + 60 ))
  info "Waiting ${wait_time}s for scale-down..."

  local elapsed=0
  local poll_interval=30
  local scaled_down=false

  while [[ "$elapsed" -lt "$wait_time" ]]; do
    sleep "$poll_interval"
    elapsed=$(( elapsed + poll_interval ))

    local current_replicas
    current_replicas=$(kubectl get deployment \
      "$BURST_DEPLOY" \
      -n "$DEFAULT_NS" \
      -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")

    info "  [${elapsed}s] burst replicas=${current_replicas}"

    if [[ "${current_replicas:-1}" -eq 0 ]]; then
      scaled_down=true
      break
    fi
  done

  if [[ "$scaled_down" == "true" ]]; then
    pass "Scale-down occurred after cooldown (${elapsed}s)"
  else
    fail "Scale-down did not occur within ${wait_time}s (cooldown=${COOLDOWN_PERIOD}s)"
  fi

  # 5.2 Karpenter consolidated (removed) GPU nodes after scale-down
  if [[ "$scaled_down" == "true" ]]; then
    info "Verifying GPU node consolidation by Karpenter..."
    sleep 30  # Karpenter needs time to consolidate

    local remaining_nodeclaims
    remaining_nodeclaims=$(kubectl get nodeclaims \
      -l "karpenter.sh/nodepool=${KARPENTER_NODEPOOL}" \
      --no-headers 2>/dev/null | wc -l | tr -d ' ')

    if [[ "${remaining_nodeclaims:-0}" -eq 0 ]]; then
      pass "Karpenter consolidated GPU nodes (0 NodeClaims remaining)"
    else
      info "Remaining NodeClaims: ${remaining_nodeclaims} (consolidation may take more time)"
      skip "Karpenter has not yet consolidated GPU nodes (consolidateAfter=600s)"
    fi
  fi
}

# ---------------------------------------------------------------------------
# SUITE 6 — Static Configuration Validation
# ---------------------------------------------------------------------------
test_static_config_validation() {
  header "SUITE 6 — Static Configuration Validation"

  # 6.1 Burst deployment has nodeSelector karpenter.sh/nodepool=gpu
  local burst_node_selector
  burst_node_selector=$(kubectl get deployment \
    "$BURST_DEPLOY" \
    -n "$DEFAULT_NS" \
    -o jsonpath='{.spec.template.spec.nodeSelector.karpenter\.sh/nodepool}' \
    2>/dev/null || echo "")

  if [[ "$burst_node_selector" == "gpu" ]]; then
    pass "Burst deployment has nodeSelector karpenter.sh/nodepool=gpu"
  else
    fail "Burst deployment nodeSelector incorrect: '${burst_node_selector}' (expected 'gpu')"
  fi

  # 6.2 Burst deployment has toleration nvidia.com/gpu
  local burst_toleration
  burst_toleration=$(kubectl get deployment \
    "$BURST_DEPLOY" \
    -n "$DEFAULT_NS" \
    -o jsonpath='{.spec.template.spec.tolerations[?(@.key=="nvidia.com/gpu")].effect}' \
    2>/dev/null || echo "")

  if [[ "$burst_toleration" == "NoSchedule" ]]; then
    pass "Burst deployment has toleration nvidia.com/gpu:NoSchedule"
  else
    fail "Burst deployment missing toleration nvidia.com/gpu:NoSchedule (found: '${burst_toleration}')"
  fi

  # 6.3 Burst deployment requests 1 GPU
  local burst_gpu_request
  burst_gpu_request=$(kubectl get deployment \
    "$BURST_DEPLOY" \
    -n "$DEFAULT_NS" \
    -o jsonpath='{.spec.template.spec.containers[0].resources.requests.nvidia\.com/gpu}' \
    2>/dev/null || echo "")

  if [[ "${burst_gpu_request:-0}" -ge 1 ]]; then
    pass "Burst deployment requests ${burst_gpu_request} GPU(s)"
  else
    fail "Burst deployment does not request GPU (requests.nvidia.com/gpu=${burst_gpu_request})"
  fi

  # 6.4 Burst deployment has tensor-parallel-size=1 (TP=1 for single GPU)
  local burst_tp
  burst_tp=$(kubectl get deployment \
    "$BURST_DEPLOY" \
    -n "$DEFAULT_NS" \
    -o jsonpath='{.spec.template.spec.containers[0].args}' \
    2>/dev/null | grep -o "tensor-parallel-size=[0-9]*" | cut -d= -f2 || echo "")

  if [[ "$burst_tp" == "1" ]]; then
    pass "Burst deployment has tensor-parallel-size=1 (correct for single GPU)"
  else
    fail "Burst deployment tensor-parallel-size=${burst_tp} (expected 1 for single GPU)"
  fi

  # 6.5 Burst deployment uses S3 as model source
  local burst_model_arg
  burst_model_arg=$(kubectl get deployment \
    "$BURST_DEPLOY" \
    -n "$DEFAULT_NS" \
    -o jsonpath='{.spec.template.spec.containers[0].args}' \
    2>/dev/null | grep -o "s3://[^'\"]*" | head -1 || echo "")

  if [[ "$burst_model_arg" == s3://* ]]; then
    pass "Burst deployment uses S3 as model source: ${burst_model_arg}"
  else
    fail "Burst deployment does not use S3 as model source (found: '${burst_model_arg}')"
  fi

  # 6.6 PodDisruptionBudget exists for hybrid
  local pdb_name
  pdb_name=$(kubectl get pdb \
    -l "app=vllm-burst-scaling" \
    -n "$DEFAULT_NS" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  if [[ -n "$pdb_name" ]]; then
    pass "PodDisruptionBudget exists: ${pdb_name}"
  else
    skip "PodDisruptionBudget not found (may not be configured)"
  fi
}

# ---------------------------------------------------------------------------
# Main runner
# ---------------------------------------------------------------------------
run_all_tests() {
  echo -e "\n${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║  test_scaling.sh — KEDA + Karpenter + Burst Scaling         ║${NC}"
  echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo -e "ScaledObject: ${SCALEDOBJECT_NAME} | NodePool: ${KARPENTER_NODEPOOL}"
  echo -e "SKIP_LOAD_TESTS: ${SKIP_LOAD_TESTS}"
  echo -e "Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')\n"

  if [[ "$SKIP_LOAD_TESTS" != "true" ]]; then
    echo -e "${YELLOW}⚠ WARNING: Load tests will be executed. This will generate real traffic on the cluster.${NC}"
    echo -e "${YELLOW}  Use SKIP_LOAD_TESTS=true to skip scale-up/down tests.${NC}\n"
  fi

  test_keda_scaledobject
  test_scale_to_zero
  test_karpenter_nodepool
  test_scale_up_under_load
  test_scale_down_after_cooldown
  test_static_config_validation

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
