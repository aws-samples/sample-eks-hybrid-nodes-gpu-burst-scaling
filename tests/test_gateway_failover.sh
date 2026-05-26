#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

set -euo pipefail

FAILURES=0
pass() { echo "  [PASS] $1"; }
fail() { echo "  [FAIL] $1"; FAILURES=$((FAILURES + 1)); }
warn() { echo "  [WARN] $1"; }

echo "=== Gateway Failover Test ==="

# Identify leader
LEASE_HOLDER=$(kubectl get lease -n eks-hybrid-nodes-gateway -o jsonpath='{.items[0].spec.holderIdentity}' 2>/dev/null || echo "")
if [[ -z "$LEASE_HOLDER" ]]; then
  fail "No lease holder found"
  echo "FAILED: Cannot proceed with failover test"
  exit 1
fi
pass "Leader identified: $LEASE_HOLDER"

# Get hybrid pod IP for connectivity check
HYBRID_IP=$(kubectl get pod -l tier=hybrid -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || echo "")

# Delete leader pod
echo "  Deleting leader pod: $LEASE_HOLDER"
kubectl delete pod "$LEASE_HOLDER" -n eks-hybrid-nodes-gateway --grace-period=0 2>/dev/null || true

# Wait for new leader (max 10s)
echo "  Waiting for new leader..."
NEW_LEADER=""
for i in $(seq 1 10); do
  sleep 1
  NEW_LEADER=$(kubectl get lease -n eks-hybrid-nodes-gateway -o jsonpath='{.items[0].spec.holderIdentity}' 2>/dev/null || echo "")
  if [[ -n "$NEW_LEADER" && "$NEW_LEADER" != "$LEASE_HOLDER" ]]; then
    break
  fi
  NEW_LEADER=""
done

if [[ -n "$NEW_LEADER" ]]; then
  pass "New leader elected within 10s: $NEW_LEADER"
else
  fail "No new leader elected within 10s"
fi

# Verify connectivity restored
if [[ -n "$HYBRID_IP" && "$HYBRID_IP" == 10.200.* ]]; then
  sleep 2
  VPC_POD=$(kubectl get pods -l app=vllm-burst-scaling -o jsonpath='{.items[0].metadata.name}' --field-selector=status.phase=Running 2>/dev/null | head -1)
  if [[ -n "$VPC_POD" ]]; then
    if kubectl exec "$VPC_POD" -- wget -qO- --timeout=5 "http://${HYBRID_IP}:8000/health" 2>/dev/null | grep -q .; then
      pass "Connectivity restored after failover"
    else
      warn "Connectivity not confirmed after failover (may need more time)"
    fi
  else
    warn "No VPC pod available for connectivity test"
  fi
else
  warn "No hybrid pod with 10.200.x.x IP for connectivity test"
fi

echo ""
echo "=== Results ==="
if [[ $FAILURES -gt 0 ]]; then
  echo "FAILED: $FAILURES check(s) failed"
  exit 1
fi
echo "ALL CHECKS PASSED"
exit 0
