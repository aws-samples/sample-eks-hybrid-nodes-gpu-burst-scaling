#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# =============================================================================
# 99-cleanup.sh — Teardown all resources created by the GPU-HybridNodes-EKS POC
#
# Purpose:
#   Reverses every action performed during Phases 1-5 in safe order:
#   uninstalls K8s workloads, resets the hybrid node, deletes EKS access entries,
#   restores cluster endpoint, runs terraform destroy, and cleans local artifacts.
#   Best-effort: individual failures log a warning and the script continues.
#
# Environment Variables:
#   CLUSTER_NAME                — EKS cluster name (default: llm-k8sv4)
#   AWS_REGION                  — AWS region (default: ap-northeast-1)
#   HYBRID_SSM_ID               — SSM managed instance ID of the hybrid node
#   HYBRID_ROLE_NAME            — IAM role name for the hybrid node
#   CILIUM_INSTALLER_ROLE_NAME  — IAM role name for cilium-installer (default: cilium-installer)
#   TERRAFORM_DIR               — Path to Terraform directory (default: <repo>/terraform)
#   FORCE                       — Set to "yes" for non-interactive mode (skip confirmation)
#   KEEP_LOCAL                  — Set to "yes" to keep local tf state/key/outputs
#
# Usage:
#   ./scripts/99-cleanup.sh
#   FORCE=yes ./scripts/99-cleanup.sh
#   KEEP_LOCAL=yes ./scripts/99-cleanup.sh
# =============================================================================

set -uo pipefail   # intentionally NOT -e

# --- Configuration ----------------------------------------------------------
CLUSTER_NAME="${CLUSTER_NAME:-llm-k8sv4}"
AWS_REGION="${AWS_REGION:-ap-northeast-1}"
HYBRID_SSM_ID="${HYBRID_SSM_ID:-$(aws ssm describe-instance-information --region "${AWS_REGION:-ap-northeast-1}" --query 'InstanceInformationList[?PingStatus==`Online`].InstanceId' --output text | grep "^mi-" | head -1)}"
HYBRID_ROLE_NAME="${HYBRID_ROLE_NAME:-eks-hybrid-node-${CLUSTER_NAME}}"
CILIUM_INSTALLER_ROLE_NAME="${CILIUM_INSTALLER_ROLE_NAME:-cilium-installer}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TERRAFORM_DIR="${TERRAFORM_DIR:-${REPO_ROOT}/terraform}"

# --- Logging ----------------------------------------------------------------
log()  { printf '\n[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
warn() { printf '\n[%s] [WARN]  %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
err()  { printf '\n[%s] [ERROR] %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }

# --- Pre-flight: AWS credentials -------------------------------------------
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
if [[ -z "${ACCOUNT_ID}" || "${ACCOUNT_ID}" == "None" ]]; then
  err "Unable to get AWS caller identity. Check credentials / SSO / AWS_PROFILE."
  exit 1
fi
HYBRID_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${HYBRID_ROLE_NAME}"
CILIUM_INSTALLER_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${CILIUM_INSTALLER_ROLE_NAME}"

# --- Helpers ----------------------------------------------------------------

# ssm_run <description> <shell_script>
# Ships `shell_script` to the hybrid node base64-encoded (JSON-safe) and waits
# for completion (max ~10 min). Best-effort: returns non-zero but never exits.
ssm_run() {
  local desc="$1"; shift
  local script="$1"; shift || true

  local b64 wrapper
  # Works on both macOS BSD base64 and Linux GNU base64.
  b64="$(printf '%s' "${script}" | base64 | tr -d '\n\r ')"
  wrapper="echo ${b64} | base64 -d | bash"

  # base64 output is [A-Za-z0-9+/=] only — safe to inline in JSON.
  local params_json
  params_json="$(printf '{"commands":["%s"]}' "${wrapper}")"

  local cmd_id
  cmd_id="$(aws ssm send-command \
    --region "${AWS_REGION}" \
    --document-name "AWS-RunShellScript" \
    --instance-ids "${HYBRID_SSM_ID}" \
    --comment "${desc:0:100}" \
    --parameters "${params_json}" \
    --query 'Command.CommandId' \
    --output text 2>/dev/null)" || true

  if [[ -z "${cmd_id:-}" || "${cmd_id}" == "None" ]]; then
    warn "SSM send-command failed for: ${desc} (hybrid node may be unreachable)"
    return 1
  fi

  log "SSM → ${HYBRID_SSM_ID} — ${desc} (CommandId=${cmd_id})"

  # Poll every 5s for up to ~10 min.
  local status="Pending"
  local i
  for i in $(seq 1 120); do
    status="$(aws ssm list-command-invocations \
      --region "${AWS_REGION}" \
      --command-id "${cmd_id}" \
      --query 'CommandInvocations[0].Status' \
      --output text 2>/dev/null || echo 'Pending')"
    case "${status}" in
      Success|Failed|Cancelled|TimedOut|Undeliverable|Terminated) break ;;
    esac
    sleep 5
  done

  # Print the (truncated) output for diagnostics.
  aws ssm get-command-invocation \
    --region "${AWS_REGION}" \
    --command-id "${cmd_id}" \
    --instance-id "${HYBRID_SSM_ID}" \
    --query '{Status:Status, StandardOutputContent:StandardOutputContent, StandardErrorContent:StandardErrorContent}' \
    --output text 2>/dev/null | sed 's/^/    | /' || true

  if [[ "${status}" != "Success" ]]; then
    warn "SSM command finished with status=${status} for: ${desc}"
    return 1
  fi
  return 0
}

# --- Confirmation banner ----------------------------------------------------
cat <<BANNER

================================================================================
  GPU-HybridNodes-EKS — CLEANUP / TEARDOWN
--------------------------------------------------------------------------------
  This script will DESTROY all resources created by this POC. The following
  actions will run in order (best-effort, individual failures do not abort):

    1. Uninstall K8s workloads on ${CLUSTER_NAME} (gpu-demo pod, nvdp, cilium)
    2. nodeadm reset on hybrid node ${HYBRID_SSM_ID}
    3. Delete EKS access entry for ${HYBRID_ROLE_ARN}
    4. Delete EKS access entry for ${CILIUM_INSTALLER_ROLE_ARN} (if present)
    5. Restore cluster endpoint to Public + Private
    6. Wait for cluster ACTIVE
    7. NOTE: RemoteNetworkConfig cannot be removed from an existing cluster
    8. terraform destroy -auto-approve  (VPC, peering, EC2, IAM, SSM activation)
    9. Remove local artifacts (tf state, plan, outputs JSON, SSH key)

  Region      : ${AWS_REGION}
  Cluster     : ${CLUSTER_NAME}
  Hybrid SSM  : ${HYBRID_SSM_ID}
  TF dir      : ${TERRAFORM_DIR}
  Account     : ${ACCOUNT_ID}

  !! This is destructive and NOT easily reversible !!
================================================================================

BANNER

if [[ "${FORCE:-}" != "yes" ]]; then
  read -r -p "Type the cluster name (${CLUSTER_NAME}) to confirm teardown: " answer
  if [[ "${answer}" != "${CLUSTER_NAME}" ]]; then
    err "Confirmation failed. Aborting."
    exit 1
  fi
fi

# ============================================================================
# Step 1/9 — Uninstall K8s workloads via SSM on the hybrid node
# ============================================================================
log "=== Step 1/9 — Uninstalling K8s workloads (helm + kubectl) via SSM ==="

WORKLOAD_SCRIPT='
set -u
export PATH=/usr/local/bin:/usr/bin:/bin

# Locate an admin kubeconfig. Helm / kubectl were used from the hybrid node in
# Phase 4 so there is typically one in /root or /home/ubuntu.
KUBECONFIG_CANDIDATES="/root/.kube/config /home/ubuntu/.kube/config /etc/kubernetes/admin.conf /var/lib/kubelet/kubeconfig"
export KUBECONFIG=""
for kc in $KUBECONFIG_CANDIDATES; do
  if sudo test -r "$kc"; then
    export KUBECONFIG="$kc"
    echo "Using KUBECONFIG=$kc"
    break
  fi
done

if [ -z "$KUBECONFIG" ]; then
  echo "No kubeconfig found on hybrid node — skipping helm/kubectl uninstalls."
  exit 0
fi

run() { echo "+ $*"; sudo -E "$@" || true; }

# Delete the demo GPU pod in common namespaces.
for ns in default gpu-demo; do
  run kubectl --kubeconfig "$KUBECONFIG" -n "$ns" delete pod gpu-demo --ignore-not-found --timeout=60s
done

# Uninstall helm releases if helm is present.
if command -v helm >/dev/null 2>&1; then
  # nvdp was installed in either nvidia-device-plugin or kube-system namespace.
  for ns in nvidia-device-plugin kube-system; do
    run helm --kubeconfig "$KUBECONFIG" -n "$ns" uninstall nvdp --wait --timeout 2m
  done

  # cilium was installed in kube-system.
  run helm --kubeconfig "$KUBECONFIG" -n kube-system uninstall cilium --wait --timeout 3m

  # Drop leftover cilium CRDs / namespaces if any.
  for crd in $(sudo kubectl --kubeconfig "$KUBECONFIG" get crd -o name 2>/dev/null | grep -E "cilium" || true); do
    run kubectl --kubeconfig "$KUBECONFIG" delete "$crd" --ignore-not-found --timeout=60s
  done
else
  echo "helm not found on hybrid node — skipping helm uninstalls."
fi

echo "Workload cleanup finished."
'
ssm_run "uninstall gpu-demo / nvdp / cilium" "${WORKLOAD_SCRIPT}" \
  || warn "K8s workload cleanup did not complete cleanly — continuing."

# ============================================================================
# Step 2/9 — nodeadm reset on the hybrid node
# ============================================================================
log "=== Step 2/9 — nodeadm reset on hybrid node ==="

NODEADM_SCRIPT='
set -u
export PATH=/usr/local/bin:/usr/bin:/bin

if ! command -v nodeadm >/dev/null 2>&1; then
  echo "nodeadm not installed — skipping."
  exit 0
fi

# --skip flags tolerate a cluster that is already unreachable.
sudo nodeadm uninstall -s node-validation,pod-validation 2>/dev/null \
  || sudo nodeadm uninstall 2>/dev/null \
  || true

# Some nodeadm versions expose `reset`; try that too (no-op if not present).
sudo nodeadm reset 2>/dev/null || true

# Best-effort: stop kubelet / containerd so the box is inert post-reset.
sudo systemctl stop kubelet 2>/dev/null || true
sudo systemctl disable kubelet 2>/dev/null || true
echo "nodeadm reset/uninstall finished."
'
ssm_run "nodeadm reset / uninstall" "${NODEADM_SCRIPT}" \
  || warn "nodeadm reset did not complete cleanly — continuing."

# ============================================================================
# Step 3/9 — Delete EKS access entry for the hybrid node IAM role
# ============================================================================
log "=== Step 3/9 — Delete EKS access entry for ${HYBRID_ROLE_ARN} ==="

if aws eks describe-access-entry \
     --cluster-name "${CLUSTER_NAME}" \
     --principal-arn "${HYBRID_ROLE_ARN}" \
     --region "${AWS_REGION}" >/dev/null 2>&1; then
  aws eks delete-access-entry \
    --cluster-name "${CLUSTER_NAME}" \
    --principal-arn "${HYBRID_ROLE_ARN}" \
    --region "${AWS_REGION}" >/dev/null \
    && log "Access entry deleted: ${HYBRID_ROLE_ARN}" \
    || warn "Failed to delete access entry: ${HYBRID_ROLE_ARN}"
else
  log "Access entry not found (already deleted): ${HYBRID_ROLE_ARN}"
fi

# ============================================================================
# Step 4/9 — Delete optional cilium-installer access entry
# ============================================================================
log "=== Step 4/9 — Delete EKS access entry for ${CILIUM_INSTALLER_ROLE_ARN} (if any) ==="

if aws eks describe-access-entry \
     --cluster-name "${CLUSTER_NAME}" \
     --principal-arn "${CILIUM_INSTALLER_ROLE_ARN}" \
     --region "${AWS_REGION}" >/dev/null 2>&1; then
  aws eks delete-access-entry \
    --cluster-name "${CLUSTER_NAME}" \
    --principal-arn "${CILIUM_INSTALLER_ROLE_ARN}" \
    --region "${AWS_REGION}" >/dev/null \
    && log "Access entry deleted: ${CILIUM_INSTALLER_ROLE_ARN}" \
    || warn "Failed to delete access entry: ${CILIUM_INSTALLER_ROLE_ARN}"
else
  log "Access entry not found (nothing to do): ${CILIUM_INSTALLER_ROLE_ARN}"
fi

# ============================================================================
# Step 5/9 — Restore cluster endpoint to Public + Private
# ============================================================================
log "=== Step 5/9 — Restoring cluster endpoint to Public + Private ==="

current_public="$(aws eks describe-cluster \
  --name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --query 'cluster.resourcesVpcConfig.endpointPublicAccess' \
  --output text 2>/dev/null || echo 'unknown')"
current_private="$(aws eks describe-cluster \
  --name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --query 'cluster.resourcesVpcConfig.endpointPrivateAccess' \
  --output text 2>/dev/null || echo 'unknown')"

if [[ "${current_public}" == "True" && "${current_private}" == "True" ]]; then
  log "Endpoint already Public+Private — no change."
else
  log "Current endpoint: public=${current_public} private=${current_private}. Updating..."
  if aws eks update-cluster-config \
       --name "${CLUSTER_NAME}" \
       --region "${AWS_REGION}" \
       --resources-vpc-config endpointPublicAccess=true,endpointPrivateAccess=true \
       >/dev/null 2>&1; then
    log "update-cluster-config submitted — waiting for ACTIVE..."
    # ============================================================================
    # Step 6/9 — Wait for cluster ACTIVE
    # ============================================================================
    log "=== Step 6/9 — Waiting for ${CLUSTER_NAME} to return to ACTIVE ==="
    if aws eks wait cluster-active \
         --name "${CLUSTER_NAME}" \
         --region "${AWS_REGION}"; then
      log "Cluster ${CLUSTER_NAME} is ACTIVE."
    else
      warn "cluster-active wait failed (cluster may still be updating)."
    fi
  else
    warn "update-cluster-config failed (maybe already in progress or cluster missing)."
  fi
fi

# ============================================================================
# Step 7/9 — RemoteNetworkConfig notice
# ============================================================================
log "=== Step 7/9 — RemoteNetworkConfig ==="
cat <<'NOTE'
  NOTE: EKS does NOT support removing `remoteNetworkConfig` from an existing
  cluster once it has been set. The only way to drop it is to delete and
  recreate the cluster. Because this POC uses a pre-existing cluster
  (llm-k8sv4) we intentionally LEAVE `remoteNetworkConfig` in place.

  Current remoteNetworkConfig:
NOTE
aws eks describe-cluster \
  --name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --query 'cluster.remoteNetworkConfig' \
  --output json 2>/dev/null || true

# ============================================================================
# Step 8/9 — terraform destroy
# ============================================================================
log "=== Step 8/9 — terraform destroy -auto-approve (${TERRAFORM_DIR}) ==="

if [[ ! -d "${TERRAFORM_DIR}" ]]; then
  warn "Terraform dir not found: ${TERRAFORM_DIR} — skipping destroy."
else
  if ! command -v terraform >/dev/null 2>&1; then
    err "terraform CLI not found on PATH. Install terraform and re-run the destroy step manually:"
    err "  cd ${TERRAFORM_DIR} && terraform destroy -auto-approve"
  else
    (
      cd "${TERRAFORM_DIR}" || exit 1

      # Ensure providers are available (safe if already initialised).
      terraform init -input=false -upgrade=false >/dev/null 2>&1 || true

      if ! terraform destroy -auto-approve -input=false; then
        warn "terraform destroy reported errors. You may need to re-run or clean up manually."
      else
        log "terraform destroy completed."
      fi
    )
  fi
fi

# ============================================================================
# Step 9/9 — Local artifacts cleanup
# ============================================================================
log "=== Step 9/9 — Local artifacts cleanup ==="

if [[ "${KEEP_LOCAL:-}" == "yes" ]]; then
  log "KEEP_LOCAL=yes set — leaving local files untouched."
else
  # Files to remove (if present). All are regenerated by `terraform init/apply`.
  local_artifacts=(
    "${TERRAFORM_DIR}/terraform.tfstate"
    "${TERRAFORM_DIR}/terraform.tfstate.backup"
    "${TERRAFORM_DIR}/tfplan"
    "${TERRAFORM_DIR}/eks-hybrid-node-${CLUSTER_NAME}.pem"
    "${REPO_ROOT}/terraform-outputs.json"
  )
  for f in "${local_artifacts[@]}"; do
    if [[ -e "${f}" ]]; then
      rm -f "${f}" && log "removed ${f}" || warn "could not remove ${f}"
    fi
  done

  # Remove .terraform/ provider cache (optional; `terraform init` recreates it).
  if [[ -d "${TERRAFORM_DIR}/.terraform" ]]; then
    rm -rf "${TERRAFORM_DIR}/.terraform" \
      && log "removed ${TERRAFORM_DIR}/.terraform" \
      || warn "could not remove ${TERRAFORM_DIR}/.terraform"
  fi
fi

log "=================================================================="
log " Cleanup complete."
log " If any step above reported [WARN] or [ERROR], inspect the output"
log " and re-run the script — it is idempotent."
log "=================================================================="
