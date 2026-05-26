#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# =============================================================================
# validate-manifests.sh — Static validation of burst-scaling manifests
# =============================================================================
# Runs kubectl --dry-run=client, checks label consistency and GPU resource
# requests across the burst-scaling manifests. No live cluster mutation.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="${ROOT}/manifests/burst-scaling"
PASS=0
FAIL=0

check() {
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "  PASS  ${name}"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  ${name}"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== Dry-run apply ==="
check "kubectl dry-run all manifests" \
    kubectl apply --dry-run=client -f "${DIR}/"

echo "=== Label consistency (model: qwen36-35b-a3b) ==="
for f in 02-hybrid-deployment.yaml 03-burst-deployment.yaml 01-service.yaml; do
    check "${f} has model label" grep -q 'model: qwen36-35b-a3b' "${DIR}/${f}"
done

echo "=== GPU resource requests ==="
check "hybrid requests 4 GPUs" \
    grep -E "nvidia.com/gpu:[[:space:]]+4" "${DIR}/02-hybrid-deployment.yaml"
check "burst requests 1 GPU" \
    grep -E "nvidia.com/gpu:[[:space:]]+1" "${DIR}/03-burst-deployment.yaml"

echo "=== KEDA ScaledObject targets burst deployment ==="
check "scaler targets qwen36-burst" \
    grep -q "name: qwen36-burst" "${DIR}/04-keda-scaledobject.yaml"

echo
echo "Result: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
