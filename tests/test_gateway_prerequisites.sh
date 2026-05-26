#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

set -euo pipefail

PASS=0
FAIL=0

check() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == *"$expected"* ]]; then
    echo "PASS: $desc"
    PASS=$((PASS+1))
  else
    echo "FAIL: $desc (expected '$expected', got '$actual')"
    FAIL=$((FAIL+1))
  fi
}

check_nonempty() {
  local desc="$1" actual="$2"
  if [[ -n "$actual" ]]; then
    echo "PASS: $desc"
    PASS=$((PASS+1))
  else
    echo "FAIL: $desc (expected non-empty value, got empty)"
    FAIL=$((FAIL+1))
  fi
}

check "Cilium image version 1.17.13" \
  "1.17.13" \
  "$(kubectl get ds cilium -n kube-system -o jsonpath='{.spec.template.spec.containers[0].image}')"

check "cilium-config enable-vtep=true" \
  "true" \
  "$(kubectl get cm cilium-config -n kube-system -o jsonpath='{.data.enable-vtep}')"

check "cilium-config enable-l7-proxy=false" \
  "false" \
  "$(kubectl get cm cilium-config -n kube-system -o jsonpath='{.data.enable-l7-proxy}')"

check_nonempty "aws-node AWS_VPC_K8S_CNI_EXCLUDE_SNAT_CIDRS set" \
  "$(kubectl get ds aws-node -n kube-system -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="AWS_VPC_K8S_CNI_EXCLUDE_SNAT_CIDRS")].value}')"

# --- Gateway Infrastructure Checks ---

check "2 nodes labeled hybrid-gateway-node=true" \
  "2" \
  "$(kubectl get nodes -l hybrid-gateway-node=true --no-headers 2>/dev/null | wc -l | tr -d ' ')"

check "Gateway nodes tainted NoSchedule" \
  "NoSchedule" \
  "$(kubectl get nodes -l hybrid-gateway-node=true -o jsonpath='{.items[0].spec.taints[?(@.key=="hybrid-gateway-node")].effect}')"

check "Gateway nodes in 2 distinct AZs" \
  "2" \
  "$(kubectl get nodes -l hybrid-gateway-node=true -o jsonpath='{.items[*].metadata.labels.topology\.kubernetes\.io/zone}' | tr ' ' '\n' | sort -u | wc -l | tr -d ' ')"

if kubectl get ds eks-pod-identity-agent -n kube-system --no-headers 2>/dev/null; then
  echo "PASS: eks-pod-identity-agent DaemonSet exists"
  PASS=$((PASS+1))
else
  echo "FAIL: eks-pod-identity-agent DaemonSet not found"
  FAIL=$((FAIL+1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
