# On-Premises Setup — Nested Hyper-V on Amazon EC2 (no vSphere needed)

This is the third way to run the on-premises side of the sample, next to a real
VMware vSphere VM (`docs/vsphere-onprem-setup.md`). It is meant for demos and
proofs of concept when you do not have vSphere hardware at hand.

An Amazon EC2 instance with **nested virtualization** runs Windows Server with
**Hyper-V**, and an Ubuntu VM inside Hyper-V is the EKS hybrid node. The hybrid
node therefore runs on a real hypervisor, behind a LAN that the host routes, the
same way it would in a customer data center. It is not an EC2 instance pretending
to be on-premises.

The design is ported from the EKS Hybrid Nodes workshop, where it runs at every
event. Everything is built by the same `terraform apply` that builds the cluster.

## Architecture

```
 EKS VPC 10.43.0.0/16                         "Data center" VPC 10.90.0.0/16
 ┌──────────────────────────┐                ┌───────────────────────────────────────┐
 │ EKS control plane ENIs   │                │ private subnet                         │
 │ managed nodes, Karpenter │   Transit      │   Hyper-V host (m8i, nested virt)      │
 │ GPU burst (spot)         │◄──Gateway────► │   Windows Server 2025 + Hyper-V        │
 │ Hybrid Nodes Gateway     │  (VPC attach)  │    └─ DCSwitch 192.168.3.0/24 (LAN)    │
 └──────────────────────────┘                │        └─ Ubuntu VM 192.168.3.11       │
                                             │           = EKS hybrid node (CPU LLM)  │
                                             │ public subnet: NAT gateway (egress)    │
                                             └───────────────────────────────────────┘
```

| Piece | What it does |
|-------|--------------|
| Data center VPC | Plays the customer site. Attached to the same Transit Gateway as the EKS VPC |
| Hyper-V host | `m8i.2xlarge` (default) with `NestedVirtualization=enabled`, source/dest check off. It **routes** the LAN, no NAT, so the hybrid node keeps its own IP end to end |
| `DCSwitch` | Hyper-V internal switch = the on-premises LAN (`onprem_node_cidr`, default `192.168.3.0/24`). The host is `.1`, the VM is `.11` |
| Ubuntu VM | Ubuntu 24.04, 6 vCPU / 16 GB / 80 GB by default. Self-joins with `nodeadm` and the SSM activation at first boot |
| NAT gateway | Internet egress for the LAN (nodeadm, container images, Hugging Face) |
| CodeBuild | Converts the Ubuntu cloud image (qcow2) to VHDX once, into a private bucket. Windows has no native qcow2 tooling |
| SSM Automation | Installs Hyper-V, reboots, builds the LAN and the VM, and waits for the node to register |

**Transport:** the data center VPC is a Transit Gateway VPC attachment, not a
Site-to-Site VPN. That keeps the demo to a single `terraform apply` with no edge
appliance to configure. The Hybrid Nodes Gateway VXLAN overlay runs on top of it
exactly as it does over the VPN. If the demo has to show the VPN itself, use the
vSphere mode, which keeps that path.

## Deploy

```bash
cd terraform-live
cp terraform.tfvars.example terraform.tfvars
# set: cluster_name, region, onprem_mode = "nested-hyperv"
# (customer_gateway_* are ignored in this mode)
export TF_VAR_grafana_admin_password='<at least 8 characters>'
terraform init
terraform apply
aws eks update-kubeconfig --name <cluster_name> --region <region>
```

The Hyper-V build runs in the background and starts as soon as the cluster exists,
so it overlaps the rest of `terraform apply`. Follow it with the command Terraform
prints:

```bash
terraform output -raw nested_setup_status_command | bash
# InProgress  CreateVM ... then Success
kubectl get nodes -l eks.amazonaws.com/compute-type=hybrid -w
```

Measured on a clean deployment in us-east-1 (2026-10-08):

| Phase | Time |
|-------|------|
| Hyper-V role install | 3 min |
| Reboot and hypervisor check | 2 min |
| Copy the VHDX, create and boot the VM | 1.5 min |
| cloud-init, `nodeadm install`/`init`, node registered | 3 min |
| **Whole automation** | **9.5 min** |
| Image conversion in CodeBuild (runs in parallel with the Hyper-V install) | 4 min |

The hybrid node was `Ready` before `terraform apply` itself returned.

Then continue with **Phase 3** of the main README (`kubectl apply -f
manifests/burst-scaling/rendered/`). The baseline pod pins to the hybrid node
through `eks.amazonaws.com/compute-type: hybrid`, so nothing in the manifests
changes between modes.

## Look inside the "data center"

The Hyper-V host is a normal managed instance, so you can show the hypervisor
during the demo:

- **Shell (no password needed):** `aws ssm start-session --target $(terraform output -raw nested_hyperv_host_instance_id)`
  then `powershell -c "Get-VM; Get-VMSwitch"`.
- **Hyper-V Manager (GUI):** the host has no key pair, so set a password first from
  that session (`net user Administrator <new-password>`). Then use Systems Manager >
  Fleet Manager > the host > *Remote Desktop* > *User credentials*, and open
  **Hyper-V Manager**: `hybrid-node-1` is the node you see in `kubectl get nodes`.

## Cost

| Component | Cost/hour (us-east-1, on-demand) |
|-----------|----------------------------------|
| Hyper-V host `m8i.2xlarge` Windows (license included) | $0.79 |
| NAT gateway (data center) | ~$0.045 + data |
| Transit Gateway attachment (data center) | ~$0.05 |

Stop the host between demo sessions if you keep the environment up: the VM starts
again with the host (`AutomaticStartAction Start`) and the node returns to `Ready`.

## Cleanup

Same as the main README: delete the workloads, wait for the GPU nodeclaims to go
away, then `terraform destroy`. The hybrid node also leaves a managed instance
(`mi-*`) registered in SSM, which Terraform does not own. Deregister it:

```bash
aws ssm describe-instance-information --region <region> \
  --filters Key=ActivationIds,Values=$(terraform output -raw ssm_activation_id) \
  --query 'InstanceInformationList[].InstanceId' --output text \
  | xargs -n1 aws ssm deregister-managed-instance --region <region> --instance-id
```

Run it before `terraform destroy`, while the activation ID output still exists.

## Troubleshooting

| Symptom | Where to look |
|---------|---------------|
| Automation `Failed` | `aws ssm get-automation-execution --automation-execution-id <id>`: the failed step names the phase (Hyper-V install, image, VM, join) |
| `WaitImageBuild` times out | CodeBuild project `<cluster_name>-hyperv-image`, log group `/aws/codebuild/<cluster_name>-hyperv-image` |
| `HealthCheck` fails (VM not answering) | Hyper-V Manager console of `hybrid-node-1`: cloud-init output. An empty seed means the user-data object is missing from the bucket |
| `WaitNodeRegistered` times out | In the VM: `journalctl -u eks-hybrid-join` and `/var/log/join-cluster.log` (egress, nodeadm install, `eks:ListAccessEntries`) |
| `InsufficientInstanceCapacity` on the host | Change `nested_host_instance_type` (any C8i/M8i/R8i size) and re-apply |
| Baseline pod `SIGILL` | Not expected here: M8i exposes AVX-512 to the VM. Check with `grep -o avx512f /proc/cpuinfo` in the VM |

Why the VM blocks `169.254.169.254`: without it the VM reaches the host's instance
metadata through Hyper-V routing, and the SSM agent prefers IMDS over the hybrid
activation, so it takes over the Windows host's `i-*` identity. A real data center
has no metadata service, so the seed blocks it before any agent is installed.
