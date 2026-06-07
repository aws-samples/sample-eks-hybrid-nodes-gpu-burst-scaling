#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

set -euo pipefail

FAILURES=0

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILURES=$((FAILURES + 1)); }
warn() { echo "  WARN: $1"; }

echo "=== Gateway Connectivity Validation ==="

# 1. Gateway pods running (hard check, expect 2)
echo "[1] Gateway pods running"
POD_COUNT=$(kubectl get pods -n eks-hybrid-nodes-gateway \
  -l app.kubernetes.io/name=eks-hybrid-nodes-gateway \
  --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$POD_COUNT" -eq 2 ]; then
  pass "2 gateway pods running"
else
  fail "Expected 2 running pods, found $POD_COUNT"
fi

# 2. Leader lease exists (hard check, expect >= 1)
echo "[2] Leader lease"
LEASE_COUNT=$(kubectl get lease -n eks-hybrid-nodes-gateway --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$LEASE_COUNT" -ge 1 ]; then
  pass "Leader lease exists ($LEASE_COUNT)"
else
  fail "No leader lease found"
fi

# 3. VPC route for 10.200.0.0/16 points to ENI (soft check)
echo "[3] VPC route target"
RT_IDS=$(kubectl get cm -n eks-hybrid-nodes-gateway eks-hybrid-nodes-gateway-config \
  -o jsonpath='{.data.routeTableIDs}' 2>/dev/null || echo "")
if [ -z "$RT_IDS" ]; then
  warn "Config map not found — skipping route check"
else
  ROUTE_TARGET=$(aws ec2 describe-route-tables --route-table-ids "$RT_IDS" \
    --query 'RouteTables[].Routes[?DestinationCidrBlock==`10.200.0.0/16`].NetworkInterfaceId' \
    --output text 2>/dev/null || echo "")
  if [[ "$ROUTE_TARGET" == eni-* ]]; then
    pass "Route 10.200.0.0/16 → $ROUTE_TARGET"
  else
    warn "Route target is not an ENI: '${ROUTE_TARGET:-<empty>}'"
  fi
fi

# 4. CiliumVTEPConfig exists (soft check)
echo "[4] CiliumVTEPConfig"
VTEP_COUNT=$(kubectl get ciliumvtepconfig --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$VTEP_COUNT" -ge 1 ]; then
  pass "CiliumVTEPConfig exists ($VTEP_COUNT)"
else
  warn "No CiliumVTEPConfig found"
fi

# 5. Connectivity: curl hybrid pod from a VPC pod (soft check)
echo "[5] Hybrid pod connectivity"
HYBRID_POD_IP=$(kubectl get pod -l tier=hybrid \
  -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || echo "")
if [[ "$HYBRID_POD_IP" == 10.200.* ]]; then
  VPC_POD=$(kubectl get pod -l tier=vpc \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [ -n "$VPC_POD" ]; then
    CURL_OUT=$(kubectl exec "$VPC_POD" -- curl -s --max-time 5 "http://${HYBRID_POD_IP}" 2>/dev/null && echo "ok" || echo "")
    if [ "$CURL_OUT" = "ok" ]; then
      pass "VPC pod reached hybrid pod at $HYBRID_POD_IP"
    else
      warn "curl to hybrid pod $HYBRID_POD_IP failed"
    fi
  else
    warn "No VPC pod found to run connectivity test"
  fi
else
  warn "No hybrid pod with 10.200.x.x IP found — skipping connectivity test"
fi

# --- Migration Validation ---
echo ""
echo "=== Migration Validation ==="

# Check hybrid pod IP is in 10.200.0.0/16 range
HYBRID_IP=$(kubectl get pod -l tier=hybrid -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || echo "")
if [[ "$HYBRID_IP" == 10.200.* ]]; then
  pass "Hybrid pod IP in remote CIDR: $HYBRID_IP"
else
  warn "Hybrid pod IP not in 10.200.x.x range: ${HYBRID_IP:-not found}"
fi

# Check hostNetwork is not set
HOST_NET=$(kubectl get pod -l tier=hybrid -o jsonpath='{.items[0].spec.hostNetwork}' 2>/dev/null || echo "")
if [[ -z "$HOST_NET" || "$HOST_NET" == "false" ]]; then
  pass "hostNetwork removed from hybrid pod"
else
  fail "hostNetwork still set: $HOST_NET"
fi

# Check Service endpoints include hybrid pod IP
ENDPOINTS=$(kubectl get endpoints qwen-burst-svc -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || echo "")
if echo "$ENDPOINTS" | grep -q "10\.200\."; then
  pass "Service endpoints include hybrid pod IP"
else
  warn "Service endpoints don't include 10.200.x.x: $ENDPOINTS"
fi

# --- NetworkPolicy Enforcement ---
echo ""
echo "=== NetworkPolicy Enforcement ==="

if [[ -n "$HYBRID_IP" && "$HYBRID_IP" == 10.200.* ]]; then
  # Create unauthorized test pod
  kubectl run netpol-test --image=busybox --restart=Never --overrides='{"spec":{"terminationGracePeriodSeconds":0}}' -- sleep 30 2>/dev/null || true
  sleep 5
  # Try to reach hybrid pod (should be blocked)
  if kubectl exec netpol-test -- wget -qO- --timeout=3 "http://${HYBRID_IP}:8000/health" 2>/dev/null; then
    warn "NetworkPolicy NOT blocking unauthorized access"
  else
    pass "NetworkPolicy blocks unauthorized pod access"
  fi
  kubectl delete pod netpol-test --force --grace-period=0 2>/dev/null || true
else
  warn "Skipping NetworkPolicy test - no hybrid pod with 10.200.x.x IP"
fi

# --- KEDA Scaling Validation ---
echo ""
echo "=== KEDA Scaling Validation ==="

# Check ScaledObject is active
SO_ACTIVE=$(kubectl get scaledobject -o jsonpath='{.items[0].status.conditions[?(@.type=="Active")].status}' 2>/dev/null || echo "")
if [[ "$SO_ACTIVE" == "True" ]]; then
  pass "ScaledObject is Active"
else
  warn "ScaledObject not Active: ${SO_ACTIVE:-not found}"
fi

# Check hybrid pod metrics available for KEDA
if kubectl get scaledobject -o jsonpath='{.items[0].spec.triggers}' 2>/dev/null | grep -q "prometheus"; then
  pass "ScaledObject has Prometheus trigger configured"
else
  warn "ScaledObject Prometheus trigger not found"
fi

# --- Latency Validation ---
echo ""
echo "=== Latency Validation ==="

# MTU test - verify no fragmentation with 1400 byte payload
if [[ -n "$HYBRID_IP" && "$HYBRID_IP" == 10.200.* ]]; then
  VPC_POD=$(kubectl get pods -l app=vllm-burst-scaling --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null | head -1)
  if [[ -n "$VPC_POD" ]]; then
    if kubectl exec "$VPC_POD" -- ping -c 1 -s 1400 -W 3 "$HYBRID_IP" 2>/dev/null | grep -q "1 received"; then
      pass "MTU test passed (1400 byte payload, no fragmentation)"
    else
      warn "MTU test failed or ping not available"
    fi
  else
    warn "No VPC pod for MTU test"
  fi
else
  warn "No hybrid pod with 10.200.x.x IP for latency tests"
fi

echo ""
echo "=== Results: $FAILURES hard failure(s) ==="
[ "$FAILURES" -eq 0 ] && exit 0 || exit 1
