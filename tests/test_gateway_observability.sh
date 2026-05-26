#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

set -euo pipefail

FAILURES=0
pass() { echo "  [PASS] $1"; }
fail() { echo "  [FAIL] $1"; FAILURES=$((FAILURES + 1)); }
warn() { echo "  [WARN] $1"; }

echo "=== Gateway Observability Checks ==="

# ServiceMonitor exists
if kubectl get servicemonitor hybrid-nodes-gateway -n monitoring --no-headers 2>/dev/null | grep -q .; then
  pass "ServiceMonitor hybrid-nodes-gateway exists"
else
  fail "ServiceMonitor hybrid-nodes-gateway not found"
fi

# PrometheusRule exists
if kubectl get prometheusrule hybrid-gateway-alerts -n monitoring --no-headers 2>/dev/null | grep -q .; then
  pass "PrometheusRule hybrid-gateway-alerts exists"
else
  fail "PrometheusRule hybrid-gateway-alerts not found"
fi

# Gateway metrics endpoint reachable
GW_POD=$(kubectl get pods -n eks-hybrid-nodes-gateway -l app.kubernetes.io/name=eks-hybrid-nodes-gateway -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -n "$GW_POD" ]]; then
  if kubectl exec "$GW_POD" -n eks-hybrid-nodes-gateway -- wget -qO- --timeout=3 http://localhost:10080/metrics 2>/dev/null | grep -q hybrid_gateway; then
    pass "Gateway metrics endpoint returns metrics"
  else
    warn "Gateway metrics endpoint not returning expected metrics"
  fi
else
  warn "No gateway pod found for metrics check"
fi

echo ""
echo "=== Results ==="
if [[ $FAILURES -gt 0 ]]; then
  echo "FAILED: $FAILURES check(s) failed"
  exit 1
fi
echo "ALL CHECKS PASSED"
exit 0
