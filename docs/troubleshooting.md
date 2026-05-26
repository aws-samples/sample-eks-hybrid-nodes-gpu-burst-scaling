# Troubleshooting Guide — GPU Hybrid Nodes on EKS

This guide documents the issues encountered while bringing up a GPU-enabled
hybrid node on an EKS cluster, along with the symptoms observed, the root
cause, and the exact fix applied.

---

## Issue 1: Terraform recreates instance on user_data change

**Symptoms:** `terraform plan` shows the EC2 instance will be destroyed and
recreated whenever the `user_data` argument is modified, even for trivial
changes. Any in-place work done on the node (installed packages, joined
cluster state, fetched credentials) is lost on apply.

**Root Cause:** The `aws_instance` resource defaults to
`user_data_replace_on_change = true`. Any change to `user_data` is treated as
a replacement trigger, forcing instance recreation.

**Fix:** After the initial bootstrap is complete and stable, tell Terraform
to ignore subsequent changes to `user_data`:

```hcl
resource "aws_instance" "hybrid_node" {
  # ...
  user_data = file("${path.module}/user_data.sh")

  lifecycle {
    ignore_changes = [user_data]
  }
}
```

Alternative: keep the default and accept recreation when `user_data` truly
needs to change (e.g., during iterative development of the bootstrap script).

---

## Issue 2: SSM Agent incompatible with IMDSv2 (snap version)

**Symptoms:** The instance is running and healthy, but it never appears in
Systems Manager. `aws ssm describe-instance-information` returns an empty
list. No Session Manager access is possible, and no association runs on the
node.

**Root Cause:** On Ubuntu images, the SSM agent is installed via snap. The
shipped `amazon-ssm-agent` v3.2.x has a known bug retrieving IMDSv2 tokens on
accounts/regions where IMDSv2 is required (token-required metadata mode).
The agent fails to register with the AWS Systems Manager endpoint.

**Fix:** In the instance `user_data`, refresh the snap to a fixed version
before anything else runs:

```bash
#!/bin/bash
set -euxo pipefail

# Refresh SSM agent FIRST — before any other bootstrap logic
snap refresh amazon-ssm-agent --classic
systemctl restart snap.amazon-ssm-agent.amazon-ssm-agent.service

# ... rest of bootstrap
```

Verify with:

```bash
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=<instance-id>"
```

---

## Issue 3: Security Group name starting with "sg-"

**Symptoms:** `terraform apply` fails with:

```
InvalidParameterValue: Security group names cannot start with 'sg-'
```

**Root Cause:** AWS reserves the `sg-` prefix for security group IDs and
rejects any security group `name` (or `name_prefix`) that begins with that
string.

**Fix:** Rename the security group so its `name` does not start with `sg-`:

```hcl
# BAD
resource "aws_security_group" "hybrid" {
  name = "sg-hybrid-node"
}

# GOOD
resource "aws_security_group" "hybrid" {
  name = "hybrid-node-sg"
}
```

---

## Issue 4: EKS Access Entry missing for hybrid node role

**Symptoms:** `nodeadm init` on the hybrid node fails during cluster
authentication with:

```
AccessDeniedException: User ... is not authorized to perform this operation
```

The node never registers with the cluster.

**Root Cause:** Amazon EKS hybrid nodes authenticate via Amazon EKS Access Entries. An
access entry of type `HYBRID_LINUX` must exist for the IAM role that the
hybrid node assumes. Without it, the control plane rejects the node
identity.

**Fix:** Create the access entry for the hybrid node role:

```bash
aws eks create-access-entry \
  --cluster-name llm-k8sv4 \
  --principal-arn <hybrid-node-role-arn> \
  --type HYBRID_LINUX
```

Confirm with:

```bash
aws eks list-access-entries --cluster-name llm-k8sv4
```

---

## Issue 5: Kubelet port 10250 not open in Security Group

**Symptoms:** The node joins the cluster and appears in `kubectl get nodes`,
but:

- `kubectl logs <pod>` times out
- `kubectl exec` hangs and fails
- Node conditions may flip or look inconsistent
- Metrics Server / HPA cannot scrape the node

**Root Cause:** The Amazon EKS control plane must reach the kubelet API on TCP
port 10250 on each node. On hybrid nodes the control plane reaches the
kubelet over the VPC path, so the node's security group must allow ingress
on 10250 from the cluster VPC CIDR. The default security group did not
include this rule.

**Fix:** Add an ingress rule on the hybrid node security group:

```hcl
resource "aws_security_group_rule" "kubelet_from_cluster_vpc" {
  type              = "ingress"
  from_port         = 10250
  to_port           = 10250
  protocol          = "tcp"
  cidr_blocks       = ["10.0.0.0/16"]  # cluster VPC CIDR
  security_group_id = aws_security_group.hybrid.id
  description       = "kubelet API from EKS control plane (via VPC)"
}
```

Or, via CLI:

```bash
aws ec2 authorize-security-group-ingress \
  --group-id <sg-id> \
  --protocol tcp \
  --port 10250 \
  --cidr 10.0.0.0/16
```

---

## Issue 6: IAM policy missing eks:DescribeCluster

**Symptoms:** `nodeadm init` fails early with:

```
not authorized to perform: eks:DescribeCluster on resource: <cluster-arn>
```

The node cannot fetch its cluster configuration and never proceeds to
kubelet startup.

**Root Cause:** The managed policy `AmazonEKSWorkerNodeMinimalPolicy` only
grants `eks-auth:AssumeRoleForPodIdentity`. It does **not** include
`eks:DescribeCluster` or `eks:ListAccessEntries`, which `nodeadm` requires
on hybrid nodes to discover cluster endpoint and CA data. Image pulls also
fail unless the role can pull from Amazon Elastic Container Registry (Amazon ECR).

**Fix:** Attach an inline policy with the missing EKS permissions and
additionally attach `AmazonEC2ContainerRegistryPullOnly`:

```hcl
resource "aws_iam_role_policy" "hybrid_nodeadm_extras" {
  name = "hybrid-nodeadm-extras"
  role = aws_iam_role.hybrid_node.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "eks:DescribeCluster",
        "eks:ListAccessEntries"
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecr_pull_only" {
  role       = aws_iam_role.hybrid_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly"
}
```

---

## Issue 7: NVIDIA Container Toolkit not installed

**Symptoms:** The NVIDIA Device Plugin pod runs on the GPU node but its
logs show:

```
No devices found. Waiting indefinitely.
```

`kubectl describe node <gpu-node>` shows no `nvidia.com/gpu` entry under
`Allocatable`. Workloads requesting `nvidia.com/gpu` remain Pending.

**Root Cause:** `containerd` on the node only has the default `runc` runtime
configured. There is no `nvidia` runtime registered, so even though the GPU
driver is present on the host, containers cannot access `/dev/nvidia*`
devices through the container runtime, and the device plugin cannot enumerate
them.

**Fix:** Install the NVIDIA Container Toolkit, register the nvidia runtime
with containerd, and restart containerd:

```bash
# Install (Ubuntu example)
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

apt-get update
apt-get install -y nvidia-container-toolkit

# Configure containerd
nvidia-ctk runtime configure --runtime=containerd --set-as-default

# Restart
systemctl restart containerd
```

Verify:

```bash
ctr --namespace k8s.io plugins ls | grep -i nvidia
nvidia-smi
```

---

## Issue 8: NVIDIA Device Plugin helm chart requires NFD labels

**Symptoms:** After installing the `nvidia-device-plugin` Helm chart, the
DaemonSet shows `DESIRED=0` and no pods are scheduled on the GPU node, even
though the node is Ready and has the correct runtime.

**Root Cause:** The default chart affinity requires the label
`feature.node.kubernetes.io/pci-10de.present=true`, which is set by the
Node Feature Discovery (NFD) operator. Hybrid nodes in this POC do not run
NFD, so no node matches the selector and the DaemonSet schedules zero pods.

**Fix:** Override the affinity in `values.yaml` to target hybrid compute
nodes directly, and disable GPU Feature Discovery (gfd) since it also
depends on NFD:

```yaml
# values.yaml for nvidia-device-plugin
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: eks.amazonaws.com/compute-type
              operator: In
              values:
                - hybrid

gfd:
  enabled: false
```

Apply:

```bash
helm upgrade --install nvidia-device-plugin \
  nvdp/nvidia-device-plugin \
  --namespace kube-system \
  -f values.yaml
```

Verify:

```bash
kubectl -n kube-system get ds nvidia-device-plugin
kubectl describe node <gpu-node> | grep nvidia.com/gpu
```

---

## General Tips

- **Check SSM connectivity first.** If the node is invisible to AWS Systems Manager,
  everything downstream (nodeadm, kubectl, debugging) becomes harder.
  ```bash
  aws ssm describe-instance-information
  ```

- **kubectl access requires being inside the VPC.** The Amazon EKS cluster
  endpoint is configured as private-only. Run `kubectl` from a bastion,
  Cloud9, a VPC-attached workstation, or via AWS Systems Manager port-forwarding — not
  from your laptop over the public internet.

- **Node `NotReady` before the CNI is installed is EXPECTED.** Do not
  treat the initial `NotReady` state as a failure. Once the CNI DaemonSet
  (e.g., Cilium or the AWS VPC CNI variant for hybrid) is healthy on the
  node, it transitions to `Ready`.

- **SSM agent identity changes after `nodeadm install`.** Before joining,
  the node registers in SSM as an EC2 instance (`i-*`). After `nodeadm`
  configures IAM Roles Anywhere / hybrid activation, the same host is
  re-registered as a managed instance (`mi-*`). Expect the `i-*` entry to
  disappear. Look for the `mi-*` entry instead.

- **Primary logs for debugging the node bootstrap:**
  ```bash
  # user_data / cloud-init output
  sudo tail -f /var/log/user-data.log
  sudo tail -f /var/log/cloud-init-output.log

  # kubelet
  sudo journalctl -u kubelet -f

  # containerd
  sudo journalctl -u containerd -f

  # nodeadm
  sudo cat /var/log/nodeadm.log
  ```
