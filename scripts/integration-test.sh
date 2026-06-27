#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# =============================================================================
# integration-test.sh — Live validation of burst-scaling deployment
# =============================================================================
# Verifies hybrid pod placement, service endpoints, in-cluster inference,
# and KEDA ScaledObject readiness. Requires a working kubectl context with
# access to the EKS cluster and the burst-scaling manifests already applied.
# =============================================================================
set -uo pipefail

PASS=0
FAIL=0
NS="${NAMESPACE:-default}"
SVC="qwen-burst-svc"

ok()  { echo "  PASS  $1"; PASS=$((PASS + 1)); }
err() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

echo "=== Hybrid pod scheduled on hybrid node ==="
HYBRID_NODE=$(kubectl -n "${NS}" get pod -l tier=hybrid \
    -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || true)
if [ -n "${HYBRID_NODE}" ]; then
    LABEL=$(kubectl get node "${HYBRID_NODE}" \
        -o jsonpath='{.metadata.labels.eks\.amazonaws\.com/compute-type}' 2>/dev/null || true)
    [ "${LABEL}" = "hybrid" ] && ok "hybrid pod on hybrid node (${HYBRID_NODE})" \
        || err "hybrid pod on node ${HYBRID_NODE} with compute-type=${LABEL}"
else
    err "no pod with label tier=hybrid found"
fi

echo "=== Service endpoints ==="
EP_COUNT=$(kubectl -n "${NS}" get endpoints "${SVC}" \
    -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | wc -w | tr -d ' ')
[ "${EP_COUNT:-0}" -ge 1 ] && ok "service ${SVC} has ${EP_COUNT} endpoint(s)" \
    || err "service ${SVC} has no endpoints"

echo "=== Inference via Service (in-cluster curl) ==="
TEST_POD="curl-test-$$"
kubectl -n "${NS}" run "${TEST_POD}" --rm -i --restart=Never \
    --image=curlimages/curl:8.10.1 --quiet -- \
    curl -sf --max-time 15 "http://${SVC}:8000/v1/models" >/tmp/models.$$ 2>&1 \
    && ok "/v1/models returned 200" \
    || err "/v1/models did not respond (see /tmp/models.$$)"

echo "=== KEDA ScaledObject status ==="
READY=$(kubectl -n "${NS}" get scaledobject qwen-burst-scaler \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
[ "${READY}" = "True" ] && ok "ScaledObject Ready=True" \
    || err "ScaledObject Ready=${READY:-unknown}"

echo
echo "Result: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
