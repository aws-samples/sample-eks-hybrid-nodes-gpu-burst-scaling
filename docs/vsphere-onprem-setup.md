# On-Premises Setup — VMware vSphere Hybrid Node

This flavor of the sample runs the **baseline** workload on a **real on-premises
node**: an Ubuntu VM in VMware vSphere (vCenter), registered into the EKS cluster
as an EKS Hybrid Node. This is the key difference from the upstream sample, which
simulates "on-premises" with a second VPC in AWS.

The node connects to AWS over a Site-to-Site VPN (Transit Gateway), and pod-to-pod
traffic between cloud and on-premises flows through the **EKS Hybrid Nodes Gateway**
(VXLAN). The baseline LLM (`Qwen2.5-1.5B-Instruct`) runs on **CPU** on this VM —
no GPU required on-premises. When the baseline saturates, KEDA + Karpenter burst
GPU spot capacity in the cloud (see main README).

> Works identically on VMware vSphere Standard, Enterprise Plus, or any vCenter-managed
> environment. The provisioning method below (template clone + `nodeadm`) is the
> standard EKS Hybrid Nodes onboarding path and does not depend on any specific
> vSphere edition or the Terraform vSphere provider.

## Prerequisites

- VMware vSphere / vCenter with capacity for one VM (specs below)
- On-premises edge router terminating the Site-to-Site VPN to AWS (e.g. pfSense,
  Cisco, Fortinet). Underlay routing is **BGP**.
- Outbound internet from the VM (for `nodeadm` install + SSM registration)
- `terraform apply` already completed for the AWS side (creates the SSM activation,
  VPN/CGW, cluster). Capture these Terraform outputs:
  - `ssm_activation_id`
  - `ssm_activation_code` (sensitive)
  - `cluster_name`, `region`

## VM specifications (baseline — CPU inference)

| Resource | Value | Notes |
|----------|-------|-------|
| vCPU | 4 | Qwen2.5-1.5B CPU inference |
| RAM | 12 GB | the vLLM CPU engine measured ~8 GiB for this model (pod requests 8Gi), plus kubelet/Cilium/Gateway overhead |
| Disk | 60 GB | OS + container images + model cache |
| OS | Ubuntu 22.04 LTS | EKS Hybrid Nodes supported OS |
| Network | On-prem LAN in `onprem_node_cidr` (default `192.168.3.0/24`) | reachable from AWS over the VPN |

> The upstream sample uses a `g6.12xlarge` GPU node for the baseline. Here the
> baseline is CPU-only on commodity on-premises hardware — the realistic enterprise
> scenario where customers do not have GPUs in their datacenter and burst to the
> cloud for GPU capacity on demand.

## Step 1 — Provision the VM in vCenter

Create an Ubuntu 22.04 VM from a template (or clone an existing one) with the specs
above. Ensure:

- The VM gets an IP in `onprem_node_cidr` (static or DHCP reservation recommended,
  so the node IP is stable across reboots).
- The default gateway routes to your on-premises edge router (the VPN endpoint),
  so the VM can reach the EKS VPC CIDR (`10.43.0.0/16`) and the internet.

## Step 2 — Bootstrap the node (install nodeadm + register)

SSH into the VM and run the bootstrap script (`scripts/onprem-node-bootstrap.sh`),
supplying the Terraform outputs:

```bash
sudo CLUSTER_NAME=<cluster_name> \
     REGION=<region> \
     ACTIVATION_ID=<ssm_activation_id> \
     ACTIVATION_CODE=<ssm_activation_code> \
     bash onprem-node-bootstrap.sh
```

The script:
1. Downloads `nodeadm` (EKS Hybrid Nodes installer)
2. Runs `nodeadm install 1.35 --credential-provider ssm` (installs kubelet, containerd, SSM agent)
3. Writes `/etc/eks/nodeadm-config.yaml` with the SSM activation
4. Runs `nodeadm init` (registers the node, starts kubelet) with a retry loop for IAM propagation

No NVIDIA driver / Container Toolkit steps — this is a CPU node.

## Step 3 — Install the CNI (Cilium with VTEP)

The Hybrid Nodes Gateway requires Cilium on the hybrid node with VTEP enabled (the
Gateway uses VXLAN). The cluster-side Cilium and `CiliumVTEPConfig` are deployed by
Terraform (`cilium.tf`). The hybrid node's Cilium agent schedules automatically once
the node joins. Verify:

```bash
kubectl get node <node-name> -o wide        # node Ready, on-prem IP
kubectl -n kube-system get pods -o wide | grep cilium | grep <node-name>
```

> Unlike Lab 1 (routable pod CIDR via Cilium BGP Control Plane), this flavor uses
> the Gateway VXLAN overlay. Cilium here acts as the VTEP endpoint
> (`CiliumVTEPConfig`); it does **not** advertise the pod CIDR via BGP. BGP is used
> only on the VPN underlay (on-prem router ↔ AWS).

## Step 4 — Verify Gateway connectivity

```bash
# Gateway pods (active-standby) on the cloud gateway nodes
kubectl -n eks-hybrid-nodes-gateway get pods -o wide

# Hybrid node is Ready and pods on it get a routable pod IP (10.201.x.x)
kubectl get pods -A -o wide | grep <node-name>
```

See the main README "Hybrid Nodes Gateway — Network Flow" section for the VXLAN
packet path and failover behavior.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `nodeadm init` fails on `eks:ListAccessEntries` | IAM propagation delay | retry (the script loops 5×); or re-run `nodeadm init` manually |
| Node `NotReady`, no Cilium pod | VPN/route to EKS VPC down | verify VPN tunnels UP and route to `10.43.0.0/16` on the on-prem router |
| Pod-to-pod cloud↔on-prem fails | Gateway VXLAN (UDP 8472) blocked | allow UDP 8472 between on-prem node and EKS nodes over the VPN |
| Node IP changed after reboot | DHCP without reservation | set a static IP / DHCP reservation for the VM |
