#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# =============================================================================
# fix-hybrid-node.sh — Post-deploy troubleshooting for the hybrid GPU node
#
# Purpose:
#   Diagnoses and fixes common issues after hybrid node deployment: nodeadm
#   init failure, NVIDIA runtime misconfiguration, GPU operator pod issues,
#   and Cilium agent status. Performs automatic remediation where possible.
#
# Environment Variables:
#   AWS_DEFAULT_REGION  — AWS region (default: ap-northeast-1)
#   CLUSTER_NAME        — EKS cluster name (default: llm-k8sv4)
#
# Prerequisites:
#   - AWS CLI configured with appropriate permissions
#   - kubectl configured for the EKS cluster
#   - SSM Session Manager plugin installed
#
# Usage:
#   ./scripts/fix-hybrid-node.sh
#   AWS_DEFAULT_REGION=us-east-1 ./scripts/fix-hybrid-node.sh
#   CLUSTER_NAME=my-cluster ./scripts/fix-hybrid-node.sh
# =============================================================================
set -uo pipefail

REGION="${AWS_DEFAULT_REGION:-ap-northeast-1}"
CLUSTER_NAME="${CLUSTER_NAME:-llm-k8sv4}"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Hybrid Node Troubleshooting & Fix Script                   ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# --- Step 1: Find the hybrid node managed instance ID ---
echo "=== Step 1: Finding hybrid node SSM instance ==="
MI_ID=$(aws ssm describe-instance-information --region "$REGION" \
  --query 'InstanceInformationList[?PingStatus==`Online` && PlatformType==`Linux`].InstanceId' \
  --output text | tr '\t' '\n' | grep "^mi-" | head -1)

if [ -z "$MI_ID" ]; then
  echo "ERROR: No online Ubuntu SSM instance found. Is the hybrid node running?"
  exit 1
fi
echo "Found: $MI_ID"
echo ""

# --- Step 2: Check if node joined the cluster ---
echo "=== Step 2: Checking if hybrid node joined the cluster ==="
NODE_STATUS=$(kubectl get node "$MI_ID" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "NOT_FOUND")

if [ "$NODE_STATUS" = "NOT_FOUND" ]; then
  echo "Node not registered in cluster. Running nodeadm init..."
  CMD_ID=$(aws ssm send-command --region "$REGION" \
    --instance-ids "$MI_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=["nodeadm init --config-source file:///etc/eks/nodeadm-config.yaml 2>&1"]' \
    --query 'Command.CommandId' --output text)
  echo "Waiting for nodeadm init (command: $CMD_ID)..."
  sleep 30
  RESULT=$(aws ssm get-command-invocation --region "$REGION" \
    --command-id "$CMD_ID" --instance-id "$MI_ID" \
    --query 'Status' --output text)
  echo "nodeadm init result: $RESULT"
  echo "Waiting 60s for node to register..."
  sleep 60
  NODE_STATUS=$(kubectl get node "$MI_ID" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "NOT_FOUND")
fi

echo "Node status: Ready=$NODE_STATUS"
echo ""

# --- Step 3: Check GPU availability ---
echo "=== Step 3: Checking GPU availability ==="
GPU_COUNT=$(kubectl get node "$MI_ID" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null || echo "0")
echo "GPUs allocatable: $GPU_COUNT"

if [ "$GPU_COUNT" = "0" ] || [ -z "$GPU_COUNT" ]; then
  echo ""
  echo "No GPUs detected. Configuring NVIDIA runtime and restarting GPU operator pods..."
  
  # Fix NVIDIA runtime
  CMD_ID=$(aws ssm send-command --region "$REGION" \
    --instance-ids "$MI_ID" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=["nvidia-ctk runtime configure --runtime=containerd --set-as-default 2>&1","systemctl restart containerd 2>&1","sleep 3","nvidia-smi 2>&1 | head -5"]' \
    --query 'Command.CommandId' --output text)
  echo "Configuring NVIDIA runtime (command: $CMD_ID)..."
  sleep 15
  RESULT=$(aws ssm get-command-invocation --region "$REGION" \
    --command-id "$CMD_ID" --instance-id "$MI_ID" \
    --query '{Status:Status,Output:StandardOutputContent}' --output json)
  echo "$RESULT" | python3 -c "import sys,json;d=json.loads(sys.stdin.read());print(d.get('Output','')[:200])" 2>/dev/null || echo "$RESULT"
  
  # Restart GPU operator pods on hybrid node
  echo ""
  echo "Restarting GPU operator pods on hybrid node..."
  kubectl delete pods -n gpu-operator --field-selector spec.nodeName="$MI_ID" 2>/dev/null
  echo "Waiting 120s for GPU operator to detect GPUs..."
  sleep 120
  
  GPU_COUNT=$(kubectl get node "$MI_ID" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null || echo "0")
  echo "GPUs allocatable after fix: $GPU_COUNT"
fi
echo ""

# --- Step 4: Check Cilium ---
echo "=== Step 4: Checking Cilium agent ==="
CILIUM_STATUS=$(kubectl get pods -n kube-system -l k8s-app=cilium --field-selector spec.nodeName="$MI_ID" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NOT_FOUND")
echo "Cilium agent: $CILIUM_STATUS"
echo ""

# --- Step 5: Summary ---
echo "=== Summary ==="
echo "  Hybrid Node:    $MI_ID"
echo "  Node Ready:     $NODE_STATUS"
echo "  GPUs:           $GPU_COUNT"
echo "  Cilium:         $CILIUM_STATUS"
echo ""

if [ "$NODE_STATUS" = "True" ] && [ "$GPU_COUNT" = "4" ] && [ "$CILIUM_STATUS" = "Running" ]; then
  echo "✅ Hybrid node is fully operational!"
  echo ""
  echo "Next steps:"
  echo "  kubectl apply -f manifests/burst-scaling/"
  echo "  bash scripts/demo-burst-scaling.sh"
else
  echo "⚠️  Some issues remain. Check the output above."
  echo ""
  echo "Manual fixes:"
  echo "  # Re-run nodeadm init:"
  echo "  aws ssm send-command --instance-ids $MI_ID --document-name AWS-RunShellScript \\"
  echo "    --parameters 'commands=[\"nodeadm init --config-source file:///etc/eks/nodeadm-config.yaml\"]' --region $REGION"
  echo ""
  echo "  # Fix NVIDIA runtime:"
  echo "  aws ssm send-command --instance-ids $MI_ID --document-name AWS-RunShellScript \\"
  echo "    --parameters 'commands=[\"nvidia-ctk runtime configure --runtime=containerd --set-as-default\",\"systemctl restart containerd\"]' --region $REGION"
  echo ""
  echo "  # Restart GPU operator pods:"
  echo "  kubectl delete pods -n gpu-operator --field-selector spec.nodeName=$MI_ID"
fi
