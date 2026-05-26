# Architecture Decision Records

This document captures the key architectural decisions made during the **GPU-HybridNodes-EKS** Proof of Concept. Each decision is recorded using the ADR (Architecture Decision Record) format, documenting the context that motivated the choice, the decision itself, its consequences, and the alternatives that were considered.

---

## ADR-1: Private Only Endpoint

**Status:** Accepted

### Context
Amazon Elastic Kubernetes Service (Amazon EKS) Hybrid Nodes must resolve the Kubernetes API server to private IP addresses reachable through the VPC Peering connection between the hybrid VPC and the cluster VPC. With a `Public and Private` endpoint, the public DNS name resolves to public IPs from outside the VPC, which breaks kubelet connectivity from hybrid nodes that must use the private path.

### Decision
Change the Amazon Elastic Kubernetes Service (Amazon EKS) cluster endpoint access configuration from `Public and Private` to **Private Only**.

### Consequences
- `kubectl` can only be used from inside the VPC (via an SSM Session Manager session on a bastion/management host).
- DNS resolution for hybrid nodes is simplified: the API server name always resolves to private IPs reachable via VPC Peering.
- Operational access to the cluster requires VPN or SSM tunneling, adding a small friction for day-to-day administration.

### Alternatives Considered
- **Public and Private endpoint with custom DNS (Route 53 Resolver / private hosted zone overrides):** kubelet on hybrid nodes does not support overriding the API server FQDN resolution in the way required, so this approach is not supported by Amazon EKS Hybrid Nodes.

---

## ADR-2: VPC Peering (not VPN / Direct Connect)

**Status:** Accepted

### Context
The POC requires private Layer-3 connectivity between the Amazon Virtual Private Cloud (Amazon VPC) that hosts the hybrid node (simulated on-premises) and the VPC that hosts the Amazon EKS control plane ENIs and managed nodes. Both VPCs live in the **same AWS account and same region**.

### Decision
Use **VPC Peering** for inter-VPC connectivity.

### Consequences
- Simple to provision and manage (a single peering connection plus route table entries).
- No hourly charge — only standard inter-AZ / data transfer costs apply.
- Low latency (AWS backbone, no encryption/decryption overhead).
- Not transitive: peering does not scale to cross-account or cross-region topologies without additional work.

### Alternatives Considered
- **Site-to-Site VPN (~$0.05/hr + data transfer):** adds recurring cost and IPsec overhead; unnecessary for a same-account/same-region POC.
- **AWS Direct Connect:** overkill for a POC; requires physical cross-connects or partner infrastructure.
- **AWS Transit Gateway (~$0.05/hr per attachment + data processing):** valuable for multi-VPC / hub-and-spoke topologies, but adds cost and complexity with no benefit for a two-VPC POC.

---

## ADR-3: SSM Hybrid Activations (not IAM Roles Anywhere)

**Status:** Accepted

### Context
Hybrid nodes need temporary AWS Identity and Access Management (IAM) credentials to authenticate against the Amazon Elastic Kubernetes Service (Amazon EKS) API and to pull images / interact with AWS services. Amazon EKS Hybrid Nodes support two credential providers: AWS Systems Manager (SSM) Hybrid Activations and IAM Roles Anywhere.

### Decision
Use **AWS Systems Manager (SSM) Hybrid Activations** as the credential provider for hybrid nodes.

### Consequences
- Minimal setup: create an activation, pass the activation code + ID to the node, and the AWS Systems Manager agent handles credential rotation.
- No public key infrastructure (PKI) required.
- Activation codes expire (default 24 hours), but once a node is registered it remains enrolled — expiry only affects the ability to register **new** nodes.
- The node appears in the AWS Systems Manager console as a managed instance with an `mi-*` ID, enabling Session Manager and Run Command out of the box.

### Alternatives Considered
- **IAM Roles Anywhere:** requires operating a Certificate Authority (or integrating with AWS Certificate Manager Private Certificate Authority), issuing and rotating X.509 certificates, and configuring trust anchors/profiles. Appropriate for production fleets with existing PKI, but too heavy for a POC.

---

## ADR-4: Cilium CNI via Helm (not Amazon EKS Add-on)

**Status:** Accepted

### Context
Hybrid nodes require a Container Network Interface (CNI) that supports an **overlay network** (VXLAN) so pod traffic can traverse the VPC Peering link without being constrained by VPC CIDR or VPC-native routing assumptions. The Amazon VPC CNI is not supported on hybrid nodes. A flexible CNI deployment is needed so the overlay, IPAM, and tolerations can be tuned.

### Decision
Install **Cilium manually via the upstream Helm chart** with VXLAN encapsulation and `cluster-pool` IPAM.

### Configuration
- Encapsulation: **VXLAN** on UDP port **8472**
- IPAM mode: **cluster-pool**
- Cluster pool CIDR: **10.200.0.0/16**
- Per-node pod CIDR mask: **/25**

### Consequences
- Full control over Cilium configuration (encapsulation, IPAM, tolerations, Berkeley Packet Filter (BPF) features).
- Coexists with the Amazon VPC CNI on managed (cloud) nodes — each node type uses the CNI appropriate to it.
- Upgrades must be managed manually (Helm), outside of the Amazon EKS add-on lifecycle.
- Requires additional tolerations on Cilium DaemonSets so they can schedule on tainted GPU hybrid nodes (see ADR-6).

### Alternatives Considered
- **Amazon EKS Cilium Add-on:** managed lifecycle but less flexible configuration surface at the time of this POC.
- **Calico:** viable but less validated with Amazon EKS Hybrid Nodes; Cilium is the upstream reference for this use case.

---

## ADR-5: NVIDIA Device Plugin (not GPU Operator)

**Status:** Accepted

### Context
The GPU on the hybrid node must be advertised to the Kubernetes scheduler as an allocatable resource (`nvidia.com/gpu`). NVIDIA drivers and the NVIDIA Container Toolkit are **pre-installed** in the Amazon Elastic Compute Cloud (Amazon EC2) user_data (see ADR-7), so the runtime layer is already in place before the node joins the cluster.

### Decision
Deploy the standalone **NVIDIA Kubernetes Device Plugin** via its Helm chart.

### Consequences
- Lightweight footprint: a single DaemonSet exposes GPUs to the kubelet.
- Fewer moving parts and faster node-ready time.
- Hard dependency on drivers + NVIDIA Container Toolkit being present on the host — if either is missing the plugin fails silently at the allocation step.

### Alternatives Considered
- **NVIDIA GPU Operator:** installs and manages drivers, NVIDIA Container Toolkit, MIG config, DCGM exporter, and the device plugin as a bundle. Excellent for heterogeneous multi-node fleets where driver lifecycle must be centrally managed, but overkill for a single-node POC where drivers are baked into user_data.

---

## ADR-6: GPU Taint for Workload Isolation

**Status:** Accepted

### Context
The cluster contains a single hybrid node equipped with an NVIDIA L4 GPU. Without isolation, the Kubernetes scheduler may place arbitrary non-GPU workloads on this node, consuming CPU/memory that should be reserved for GPU workloads and wasting a scarce resource.

### Decision
Apply the taint `nvidia.com/gpu=Exists:NoSchedule` to the GPU hybrid node.

### Consequences
- Only pods that explicitly tolerate `nvidia.com/gpu` can be scheduled on the node.
- System components that **must** run on every node (Cilium agent, kube-proxy, NVIDIA Device Plugin, node exporters) require matching tolerations in their DaemonSet specs.
- GPU capacity is protected from eviction pressure by non-GPU workloads.

### Alternatives Considered
- **No taint:** simpler, but any pod could land on the GPU node, potentially starving GPU workloads of CPU/memory and defeating the purpose of the dedicated hybrid node.

---

## ADR-7: Full Bootstrap via Amazon EC2 User Data (not manual setup)

**Status:** Accepted

### Context
Early iterations of the POC used a manual procedure: SSH/SSM into the instance, install drivers, install `nodeadm`, and run `nodeadm init`. This approach proved fragile — SSM agent corruption, interactive session drops, and partial installs left the instance in inconsistent states that were hard to debug.

### Decision
Perform the **entire node bootstrap in Amazon EC2 user_data**: NVIDIA driver install, NVIDIA Container Toolkit install, `nodeadm` install, and `nodeadm init` with the Amazon EKS cluster configuration.

### Consequences
- The instance becomes fully configured on first boot (~10 minutes end-to-end).
- Reproducible and idempotent by construction: if something breaks, terminate and recreate the instance rather than debugging partial state.
- Bootstrap logic is versioned in Terraform alongside the infrastructure.

### Trade-offs
- The AWS Systems Manager Hybrid Activation code is embedded in the user_data script. This is acceptable for a POC because user_data is only readable by principals with `ec2:DescribeInstanceAttribute` on the instance. **For production**, the activation code should be fetched at boot from **AWS Secrets Manager** (or AWS Systems Manager Parameter Store with `SecureString`) using the instance profile.

---

## ADR-8: Single-Node POC (not multi-node)

**Status:** Accepted

### Context
The goal of this POC is to validate the **Amazon EKS Hybrid Nodes + GPU** concept: can a remote (hybrid) node with an attached GPU join an Amazon EKS cluster, receive workloads, and expose GPU resources to pods? A full production topology would introduce scale-related concerns (cross-node pod networking, HA, BGP) that are not required to answer the core question.

### Decision
Deploy a **single hybrid node** using an Amazon EC2 `g6.12xlarge` instance (4× NVIDIA L4 GPU).

### Consequences
- Networking validation is limited to single-node scenarios — no pod-to-pod cross-node traffic over the overlay is exercised.
- No high-availability testing for the Cilium operator or control-plane-facing components on hybrid nodes.
- Sufficient to prove the concept end-to-end: registration, CNI overlay, GPU scheduling, and a GPU workload running on the hybrid node.

### Production Considerations (out of scope for this POC)
- Multiple hybrid nodes across failure domains.
- **BGP** (Cilium BGP Control Plane or a dedicated router) for pod CIDR routing instead of pure VXLAN overlay where on-prem infrastructure benefits from native routing.
- High availability (HA) deployment of the Cilium operator and other singleton components.
- Activation code delivery via AWS Secrets Manager (see ADR-7).
- Centralized driver/toolkit lifecycle via the NVIDIA GPU Operator (see ADR-5).
