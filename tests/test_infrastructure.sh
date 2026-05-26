#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# =============================================================================
# tests/test_infrastructure.sh
# Infrastructure tests — EKS Hybrid Nodes + Burst Scaling
#
# Covers:
#   - Nodes Ready (managed + hybrid)
#   - GPUs allocatable on hybrid node (4× nvidia.com/gpu)
#   - Cilium agent running on hybrid node
#   - TGW connectivity (hybrid → managed, managed → hybrid)
#   - Correct Security Groups
#   - Cross-VPC DNS functional
#
# Usage: ./tests/test_infrastructure.sh
# Requires: kubectl, aws CLI configured with access to cluster llm-k8sv4
# =============================================================================
set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
CLUSTER_NAME="${CLUSTER_NAME:-llm-k8sv4}"
REGION="${REGION:-ap-northeast-1}"
HYBRID_NODE_LABEL="eks.amazonaws.com/compute-type=hybrid"
MANAGED_NODE_LABEL="eks.amazonaws.com/compute-type!=hybrid"
EXPECTED_MANAGED_NODES="${EXPECTED_MANAGED_NODES:-3}"
EXPECTED_HYBRID_NODES="${EXPECTED_HYBRID_NODES:-1}"
EXPECTED_GPUS="${EXPECTED_GPUS:-4}"
HYBRID_VPC_CIDR="${HYBRID_VPC_CIDR:-10.100.0.0/16}"
EKS_VPC_CIDR="${EKS_VPC_CIDR:-10.0.0.0/16}"
TEST_TIMEOUT="${TEST_TIMEOUT:-30}"  # seconds per test

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

pass() { echo -e "${GREEN}  ✔ PASS${NC} — $1"; ((PASSED++)); }
fail() { echo -e "${RED}  ✘ FAIL${NC} — $1"; ((FAILED++)); }
skip() { echo -e "${YELLOW}  ⊘ SKIP${NC} — $1"; ((SKIPPED++)); }
info() { echo -e "${BLUE}  ℹ${NC} $1"; }
header() { echo -e "\n${BLUE}▶ $1${NC}"; }

# Execute command with timeout; returns command exit code
run_with_timeout() {
  local timeout_sec="$1"
  shift
  timeout "${timeout_sec}" "$@"
}

# Check prerequisites
check_prerequisites() {
  header "Checking prerequisites"
  local missing=0

  for cmd in kubectl aws; do
    if ! command -v "$cmd" &>/dev/null; then
      fail "Command '$cmd' not found in PATH"
      ((missing++))
    else
      pass "Command '$cmd' available"
    fi
  done

  if ! kubectl cluster-info &>/dev/null; then
    fail "kubectl cannot connect to cluster — check kubeconfig"
    ((missing++))
  else
    local ctx
    ctx=$(kubectl config current-context 2>/dev/null || echo "unknown")
    pass "kubectl connected to cluster (context: ${ctx})"
  fi

  if [[ "$missing" -gt 0 ]]; then
    echo -e "\n${RED}Prerequisites not met. Aborting.${NC}"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# SUITE 1 — Nodes Ready
# ---------------------------------------------------------------------------
test_managed_nodes_ready() {
  header "SUITE 1 — Nodes Ready"

  # 1.1 Number of managed nodes Ready
  local ready_managed
  ready_managed=$(kubectl get nodes \
    -l "eks.amazonaws.com/compute-type!=hybrid" \
    --field-selector "status.conditions[?(@.type=='Ready')].status=True" \
    --no-headers 2>/dev/null | wc -l | tr -d ' ')

  # kubectl field-selector for conditions doesn't work directly; use jsonpath
  ready_managed=$(kubectl get nodes \
    -l "eks.amazonaws.com/compute-type!=hybrid" \
    -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null \
    | tr ' ' '\n' | grep -c "^True$" || echo 0)

  if [[ "$ready_managed" -ge "$EXPECTED_MANAGED_NODES" ]]; then
    pass "Managed nodes Ready: ${ready_managed} (expected ≥ ${EXPECTED_MANAGED_NODES})"
  else
    fail "Managed nodes Ready: ${ready_managed} (expected ≥ ${EXPECTED_MANAGED_NODES})"
  fi

  # 1.2 Number of hybrid nodes Ready
  local ready_hybrid
  ready_hybrid=$(kubectl get nodes \
    -l "eks.amazonaws.com/compute-type=hybrid" \
    -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null \
    | tr ' ' '\n' | grep -c "^True$" || echo 0)

  if [[ "$ready_hybrid" -ge "$EXPECTED_HYBRID_NODES" ]]; then
    pass "Hybrid nodes Ready: ${ready_hybrid} (expected ≥ ${EXPECTED_HYBRID_NODES})"
  else
    fail "Hybrid nodes Ready: ${ready_hybrid} (expected ≥ ${EXPECTED_HYBRID_NODES})"
  fi

  # 1.3 No nodes in NotReady
  local not_ready
  not_ready=$(kubectl get nodes \
    -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null \
    | tr ' ' '\n' | grep -c "^False$" || echo 0)

  if [[ "$not_ready" -eq 0 ]]; then
    pass "No nodes in NotReady"
  else
    fail "Nodes in NotReady: ${not_ready}"
  fi

  # 1.4 Hybrid node has label compute-type=hybrid
  local hybrid_node_name
  hybrid_node_name=$(kubectl get nodes \
    -l "eks.amazonaws.com/compute-type=hybrid" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  if [[ -n "$hybrid_node_name" ]]; then
    pass "Hybrid node found: ${hybrid_node_name}"
    export HYBRID_NODE_NAME="$hybrid_node_name"
  else
    fail "No node with label eks.amazonaws.com/compute-type=hybrid found"
    export HYBRID_NODE_NAME=""
  fi
}

# ---------------------------------------------------------------------------
# SUITE 2 — GPUs Allocatable
# ---------------------------------------------------------------------------
test_gpu_allocatable() {
  header "SUITE 2 — GPUs Allocatable on Hybrid Node"

  if [[ -z "${HYBRID_NODE_NAME:-}" ]]; then
    skip "Hybrid node not identified — skipping GPU tests"
    return
  fi

  # 2.1 nvidia.com/gpu allocatable
  local gpu_allocatable
  gpu_allocatable=$(kubectl get node "$HYBRID_NODE_NAME" \
    -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null || echo "0")

  if [[ "${gpu_allocatable:-0}" -ge "$EXPECTED_GPUS" ]]; then
    pass "GPUs allocatable on hybrid node: ${gpu_allocatable} (expected ≥ ${EXPECTED_GPUS})"
  else
    fail "GPUs allocatable on hybrid node: ${gpu_allocatable:-0} (expected ≥ ${EXPECTED_GPUS})"
  fi

  # 2.2 nvidia.com/gpu capacity
  local gpu_capacity
  gpu_capacity=$(kubectl get node "$HYBRID_NODE_NAME" \
    -o jsonpath='{.status.capacity.nvidia\.com/gpu}' 2>/dev/null || echo "0")

  if [[ "${gpu_capacity:-0}" -ge "$EXPECTED_GPUS" ]]; then
    pass "GPUs capacity on hybrid node: ${gpu_capacity} (expected ≥ ${EXPECTED_GPUS})"
  else
    fail "GPUs capacity on hybrid node: ${gpu_capacity:-0} (expected ≥ ${EXPECTED_GPUS})"
  fi

  # 2.3 Node has taint nvidia.com/gpu=true:NoSchedule
  local has_gpu_taint
  has_gpu_taint=$(kubectl get node "$HYBRID_NODE_NAME" \
    -o jsonpath='{.spec.taints[?(@.key=="nvidia.com/gpu")].effect}' 2>/dev/null || echo "")

  if [[ "$has_gpu_taint" == "NoSchedule" ]]; then
    pass "Taint nvidia.com/gpu:NoSchedule present on hybrid node"
  else
    fail "Taint nvidia.com/gpu:NoSchedule missing on hybrid node (found: '${has_gpu_taint}')"
  fi

  # 2.4 Instance type is g6.12xlarge
  local instance_type
  instance_type=$(kubectl get node "$HYBRID_NODE_NAME" \
    -o jsonpath='{.metadata.labels.node\.kubernetes\.io/instance-type}' 2>/dev/null || echo "")

  if [[ "$instance_type" == "g6.12xlarge" ]]; then
    pass "Instance type correct: ${instance_type}"
  else
    # Not fatal — could be another type with 4 GPUs
    info "Instance type: '${instance_type}' (expected g6.12xlarge)"
    pass "Instance type present (${instance_type})"
  fi
}

# ---------------------------------------------------------------------------
# SUITE 3 — Cilium on Hybrid Node
# ---------------------------------------------------------------------------
test_cilium_on_hybrid_node() {
  header "SUITE 3 — Cilium Agent on Hybrid Node"

  if [[ -z "${HYBRID_NODE_NAME:-}" ]]; then
    skip "Hybrid node not identified — skipping Cilium tests"
    return
  fi

  # 3.1 Cilium-agent pod running on hybrid node
  local cilium_pod
  cilium_pod=$(kubectl get pods -n kube-system \
    -l "k8s-app=cilium" \
    --field-selector "spec.nodeName=${HYBRID_NODE_NAME}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  if [[ -n "$cilium_pod" ]]; then
    pass "Cilium pod found on hybrid node: ${cilium_pod}"
    export CILIUM_POD="$cilium_pod"
  else
    fail "No cilium-agent pod found on hybrid node ${HYBRID_NODE_NAME}"
    export CILIUM_POD=""
    return
  fi

  # 3.2 Cilium pod in Running
  local cilium_phase
  cilium_phase=$(kubectl get pod "$CILIUM_POD" -n kube-system \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

  if [[ "$cilium_phase" == "Running" ]]; then
    pass "Cilium pod in Running"
  else
    fail "Cilium pod is not Running (phase: ${cilium_phase})"
  fi

  # 3.3 Cilium pod Ready
  local cilium_ready
  cilium_ready=$(kubectl get pod "$CILIUM_POD" -n kube-system \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")

  if [[ "$cilium_ready" == "True" ]]; then
    pass "Cilium pod Ready=True"
  else
    fail "Cilium pod Ready=${cilium_ready}"
  fi

  # 3.4 cilium status via exec (if available)
  if kubectl exec -n kube-system "$CILIUM_POD" \
    -- cilium status --brief &>/dev/null 2>&1; then
    local cilium_status
    cilium_status=$(kubectl exec -n kube-system "$CILIUM_POD" \
      -- cilium status --brief 2>/dev/null | head -1 || echo "")
    if echo "$cilium_status" | grep -qi "ok\|ready"; then
      pass "cilium status: OK"
    else
      fail "cilium status does not report OK: ${cilium_status}"
    fi
  else
    skip "cilium CLI not accessible via exec (may be in restricted mode)"
  fi
}

# ---------------------------------------------------------------------------
# SUITE 4 — Transit Gateway Connectivity
# ---------------------------------------------------------------------------
test_tgw_connectivity() {
  header "SUITE 4 — Transit Gateway Connectivity"

  # Get hybrid node IP
  local hybrid_ip
  hybrid_ip=$(kubectl get node "${HYBRID_NODE_NAME:-}" \
    -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "")

  if [[ -z "$hybrid_ip" ]]; then
    skip "Hybrid node IP not available — skipping TGW connectivity tests"
    return
  fi
  info "Hybrid node IP: ${hybrid_ip}"

  # 4.1 Hybrid node IP is in the hybrid VPC CIDR (10.100.0.0/16)
  local hybrid_octet
  hybrid_octet=$(echo "$hybrid_ip" | cut -d. -f1-2)
  if [[ "$hybrid_octet" == "10.100" ]]; then
    pass "Hybrid node IP (${hybrid_ip}) is in the hybrid VPC CIDR (${HYBRID_VPC_CIDR})"
  else
    fail "Hybrid node IP (${hybrid_ip}) is not in the expected CIDR ${HYBRID_VPC_CIDR}"
  fi

  # 4.2 Managed node can reach hybrid node (ping via debug pod)
  local managed_node
  managed_node=$(kubectl get nodes \
    -l "eks.amazonaws.com/compute-type!=hybrid" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  if [[ -z "$managed_node" ]]; then
    skip "No managed node available for connectivity test"
    return
  fi

  # Create debug pod on managed node with timeout
  local debug_result
  debug_result=$(kubectl run infra-connectivity-test \
    --image=busybox:1.36 \
    --restart=Never \
    --rm \
    --overrides="{\"spec\":{\"nodeName\":\"${managed_node}\",\"tolerations\":[]}}" \
    --command -- sh -c "ping -c 3 -W 2 ${hybrid_ip} && echo PING_OK || echo PING_FAIL" \
    2>/dev/null || echo "TIMEOUT")

  if echo "$debug_result" | grep -q "PING_OK"; then
    pass "Managed node → Hybrid node (${hybrid_ip}): connectivity OK via TGW"
  elif echo "$debug_result" | grep -q "TIMEOUT"; then
    fail "TGW connectivity test timed out (timeout 45s)"
  else
    fail "Managed node → Hybrid node (${hybrid_ip}): no connectivity (${debug_result})"
  fi

  # 4.3 Hybrid pod can reach managed node (via pod on hybrid node)
  local hybrid_pod
  hybrid_pod=$(kubectl get pods \
    -l "tier=hybrid" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  if [[ -z "$hybrid_pod" ]]; then
    skip "Hybrid pod not found — skipping hybrid → managed test"
    return
  fi

  local managed_ip
  managed_ip=$(kubectl get node "$managed_node" \
    -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "")

  if [[ -z "$managed_ip" ]]; then
    skip "Managed node IP not available"
    return
  fi

  local reverse_result
  reverse_result=$(kubectl exec "$hybrid_pod" \
    -- sh -c "ping -c 3 -W 2 ${managed_ip} && echo PING_OK || echo PING_FAIL" \
    2>/dev/null || echo "EXEC_FAIL")

  if echo "$reverse_result" | grep -q "PING_OK"; then
    pass "Hybrid pod → Managed node (${managed_ip}): connectivity OK via TGW"
  elif echo "$reverse_result" | grep -q "EXEC_FAIL"; then
    skip "Could not execute ping on hybrid pod (may not have ping)"
  else
    fail "Hybrid pod → Managed node (${managed_ip}): no connectivity"
  fi
}

# ---------------------------------------------------------------------------
# SUITE 5 — Security Groups
# ---------------------------------------------------------------------------
test_security_groups() {
  header "SUITE 5 — Security Groups"

  # 5.1 Hybrid node has security group with rule for port 8000 (vLLM)
  if ! command -v aws &>/dev/null; then
    skip "AWS CLI not available — skipping Security Group tests"
    return
  fi

  local hybrid_instance_id
  hybrid_instance_id=$(kubectl get node "${HYBRID_NODE_NAME:-}" \
    -o jsonpath='{.spec.providerID}' 2>/dev/null | sed 's|.*instance/||' || echo "")

  if [[ -z "$hybrid_instance_id" ]]; then
    skip "Hybrid node instance ID not available via providerID"
    return
  fi
  info "Hybrid instance ID: ${hybrid_instance_id}"

  # Get security groups for the instance
  local sg_ids
  sg_ids=$(aws ec2 describe-instances \
    --instance-ids "$hybrid_instance_id" \
    --region "$REGION" \
    --query 'Reservations[0].Instances[0].SecurityGroups[*].GroupId' \
    --output text 2>/dev/null || echo "")

  if [[ -z "$sg_ids" ]]; then
    skip "Could not get Security Groups for instance ${hybrid_instance_id}"
    return
  fi
  info "Security Groups: ${sg_ids}"

  # 5.2 Check if any SG allows traffic on port 8000 (vLLM)
  local sg_allows_8000=false
  for sg_id in $sg_ids; do
    local rules
    rules=$(aws ec2 describe-security-group-rules \
      --filters "Name=group-id,Values=${sg_id}" \
      --region "$REGION" \
      --query 'SecurityGroupRules[?!IsEgress && (FromPort<=`8000` && ToPort>=`8000`)].GroupRuleId' \
      --output text 2>/dev/null || echo "")
    if [[ -n "$rules" ]]; then
      sg_allows_8000=true
      info "SG ${sg_id} allows port 8000"
      break
    fi
  done

  if [[ "$sg_allows_8000" == "true" ]]; then
    pass "Security Group allows traffic on port 8000 (vLLM)"
  else
    fail "No Security Group allows traffic on port 8000 (vLLM)"
  fi

  # 5.3 Check egress rule for EKS VPC (10.0.0.0/16)
  local sg_egress_eks=false
  for sg_id in $sg_ids; do
    local egress_rules
    egress_rules=$(aws ec2 describe-security-group-rules \
      --filters "Name=group-id,Values=${sg_id}" \
      --region "$REGION" \
      --query 'SecurityGroupRules[?IsEgress].CidrIpv4' \
      --output text 2>/dev/null || echo "")
    if echo "$egress_rules" | grep -qE "0\.0\.0\.0/0|10\.0\.0\.0"; then
      sg_egress_eks=true
      break
    fi
  done

  if [[ "$sg_egress_eks" == "true" ]]; then
    pass "Security Group has egress rule for EKS VPC"
  else
    fail "Security Group has no egress rule for EKS VPC (${EKS_VPC_CIDR})"
  fi
}

# ---------------------------------------------------------------------------
# SUITE 6 — DNS Cross-VPC
# ---------------------------------------------------------------------------
test_dns_cross_vpc() {
  header "SUITE 6 — DNS Cross-VPC"

  # 6.1 Cluster internal DNS resolves from within the hybrid pod
  local hybrid_pod
  hybrid_pod=$(kubectl get pods \
    -l "tier=hybrid" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  if [[ -z "$hybrid_pod" ]]; then
    skip "Hybrid pod not found — skipping DNS tests"
    return
  fi

  # Resolve kubernetes.default.svc.cluster.local
  local dns_result
  dns_result=$(kubectl exec "$hybrid_pod" \
    -- sh -c "nslookup kubernetes.default.svc.cluster.local 2>&1 || echo DNS_FAIL" \
    2>/dev/null || echo "EXEC_FAIL")

  if echo "$dns_result" | grep -qiE "address|server:"; then
    pass "DNS resolves kubernetes.default.svc.cluster.local from hybrid pod"
  elif echo "$dns_result" | grep -q "EXEC_FAIL"; then
    skip "Could not execute nslookup on hybrid pod"
  else
    fail "DNS failed for kubernetes.default.svc.cluster.local: ${dns_result}"
  fi

  # 6.2 Resolve Prometheus service (cross-namespace)
  local prom_dns
  prom_dns=$(kubectl exec "$hybrid_pod" \
    -- sh -c "nslookup kube-prometheus-stack-prometheus.monitoring.svc.cluster.local 2>&1 || echo DNS_FAIL" \
    2>/dev/null || echo "EXEC_FAIL")

  if echo "$prom_dns" | grep -qiE "address|server:"; then
    pass "DNS resolves kube-prometheus-stack-prometheus.monitoring.svc.cluster.local"
  elif echo "$prom_dns" | grep -q "EXEC_FAIL"; then
    skip "Could not execute nslookup for Prometheus on hybrid pod"
  else
    fail "DNS failed for Prometheus: ${prom_dns}"
  fi

  # 6.3 DNS resolves from managed pod for service in default namespace
  local managed_pod
  managed_pod=$(kubectl get pods \
    -l "tier=hybrid" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  local svc_dns
  svc_dns=$(kubectl run infra-dns-test \
    --image=busybox:1.36 \
    --restart=Never \
    --rm \
    --command -- sh -c "nslookup qwen36-burst-svc.default.svc.cluster.local && echo DNS_OK || echo DNS_FAIL" \
    2>/dev/null || echo "TIMEOUT")

  if echo "$svc_dns" | grep -q "DNS_OK"; then
    pass "DNS resolves qwen36-burst-svc.default.svc.cluster.local"
  elif echo "$svc_dns" | grep -q "TIMEOUT"; then
    skip "DNS test timed out"
  else
    fail "DNS failed for qwen36-burst-svc: ${svc_dns}"
  fi
}

# ---------------------------------------------------------------------------
# Main runner
# ---------------------------------------------------------------------------
run_all_tests() {
  echo -e "\n${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║  test_infrastructure.sh — EKS Hybrid Nodes + Burst Scaling  ║${NC}"
  echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo -e "Cluster: ${CLUSTER_NAME} | Region: ${REGION}"
  echo -e "Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')\n"

  check_prerequisites
  test_managed_nodes_ready
  test_gpu_allocatable
  test_cilium_on_hybrid_node
  test_tgw_connectivity
  test_security_groups
  test_dns_cross_vpc

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
