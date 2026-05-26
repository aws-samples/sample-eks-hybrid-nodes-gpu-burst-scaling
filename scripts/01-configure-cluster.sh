#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# =============================================================================
# Phase 2 — Configure EKS Cluster for Hybrid Nodes
# =============================================================================
# Purpose:
#   Configure the existing EKS cluster `llm-k8sv4` to support AWS EKS Hybrid
#   Nodes by:
#     1. Switching the control-plane endpoint to Private Only.
#     2. Enabling RemoteNetworkConfig with the on-prem node/pod CIDRs.
#
# Prerequisites:
#   - AWS CLI v2 configured with credentials that can update the EKS cluster.
#   - The cluster `llm-k8sv4` already exists and is in ACTIVE status.
#   - VPC peering + route tables in place so a private endpoint stays reachable
#     from the hybrid-node VPC (10.100.0.0/24).
#
# IMPORTANT:
#   EKS accepts only ONE cluster-config update at a time. Each step MUST wait
#   for the cluster to return to ACTIVE before the next one is issued.
#
#   After Step 1 (endpoint -> Private Only), kubectl from the local machine
#   will stop working. Subsequent kubectl operations must be executed from
#   inside the VPC (e.g. the EC2 bastion via SSM Session Manager).
#
# Usage:
#   bash scripts/01-configure-cluster.sh
# =============================================================================

set -euo pipefail

# --- Configuration -----------------------------------------------------------
CLUSTER_NAME="${CLUSTER_NAME:-llm-k8sv4}"
AWS_REGION="${AWS_REGION:-ap-northeast-1}"
REMOTE_NODE_CIDR="10.100.0.0/24"
REMOTE_POD_CIDR="10.200.0.0/16"

# --- Helpers -----------------------------------------------------------------
log() { printf '\n[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }

wait_active() {
  log "Waiting for cluster ${CLUSTER_NAME} to reach ACTIVE status..."
  aws eks wait cluster-active \
    --name "${CLUSTER_NAME}" \
    --region "${AWS_REGION}"
  log "Cluster ${CLUSTER_NAME} is ACTIVE."
}

# --- Step 0: Pre-flight ------------------------------------------------------
log "Pre-flight: current cluster configuration"
aws eks describe-cluster \
  --name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --query 'cluster.{status:status,endpointPublicAccess:resourcesVpcConfig.endpointPublicAccess,endpointPrivateAccess:resourcesVpcConfig.endpointPrivateAccess,remoteNetworkConfig:remoteNetworkConfig}' \
  --output json

# --- Step 1: Endpoint -> Private Only ----------------------------------------
log "Step 1/2: Updating endpoint access to Private Only"
aws eks update-cluster-config \
  --name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --resources-vpc-config endpointPublicAccess=false,endpointPrivateAccess=true

wait_active

# --- Step 2: Enable RemoteNetworkConfig --------------------------------------
log "Step 2/2: Enabling RemoteNetworkConfig (nodes=${REMOTE_NODE_CIDR}, pods=${REMOTE_POD_CIDR})"
aws eks update-cluster-config \
  --name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --remote-network-config "{\"remoteNodeNetworks\":[{\"cidrs\":[\"${REMOTE_NODE_CIDR}\"]}],\"remotePodNetworks\":[{\"cidrs\":[\"${REMOTE_POD_CIDR}\"]}]}"

wait_active

# --- Step 3: Validation ------------------------------------------------------
log "Validation: final cluster configuration"
aws eks describe-cluster \
  --name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --query 'cluster.{status:status,endpoint:endpoint,remoteNetworkConfig:remoteNetworkConfig,resourcesVpcConfig:resourcesVpcConfig.{endpointPublicAccess:endpointPublicAccess,endpointPrivateAccess:endpointPrivateAccess}}' \
  --output json

log "Phase 2 complete."
log "Reminder: kubectl must now be executed from inside the VPC (bastion via SSM)."
