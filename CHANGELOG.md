# Changelog

All notable changes to this project will be documented in this file.
Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [2026-05-18] - Minor Fixes

### Added
- `terraform-live/manifests.tf`: Auto-renders manifest templates with Terraform variables (region, S3 bucket, DLC account ID) to `manifests/burst-scaling/rendered/`
- `manifests/burst-scaling/02-hybrid-deployment.yaml.tpl`: Terraform template for hybrid deployment
- `manifests/burst-scaling/03-burst-deployment.yaml.tpl`: Terraform template for burst deployment
- `terraform-live/variables.tf`: New variable `dlc_account_id` (default: 763104351884)

### Changed
- `tests/test_observability.sh`: Removed hardcoded Basic Auth credential; now reads from `GRAFANA_ADMIN_PASSWORD` env var
- `tests/test_scaling.sh`, `tests/test_inference.sh`, `tests/test_e2e.sh`: Translated Portuguese messages to English
- `CHANGELOG.md`: Sanitized instance IDs
- `README.md`: Added Shared Responsibility Model reference, Production Security Hardening table, updated deploy instructions for rendered manifests
- `.gitignore`: Added `manifests/burst-scaling/rendered/`
- `terraform.tfvars.example`: Documented `dlc_account_id` variable

---

## [2026-05-17] - Holmes CSR Compliance & Threat Model

### Added — Security Documentation
- `docs/threat-model.md`: Complete threat model following AWS SA Simplified Threat Model Template — 14 threats, 14 mitigations, 9 accepted risks, OWASP LLM Top 10 assessment, production hardening recommendations
- `docs/scan-report-analysis.md`: Detailed analysis of Holmes CSR scan findings with prioritized action plan

### Added — AI/ML Compliance
- README.md: "AI/ML Model Information" section with model license (Apache 2.0), demo disclaimer, responsible AI guidance, safety controls disclosure, and dataset compliance

### Changed — AWS Service Name Standards
- README.md, docs/architecture-decisions.md, docs/cost-analysis-burst-scaling.md, docs/troubleshooting.md, manifests/burst-scaling/README.md: First mention of each AWS service expanded to full official name (e.g., "Amazon Elastic Kubernetes Service (Amazon EKS)")

### Added — Security Controls
- `terraform-live/model-storage.tf`: S3 bucket policy `DenyInsecureTransport` enforcing TLS-only access

### Added — Legal Compliance
- All `.tf` and `.sh` files (54 total): SPDX copyright headers (`Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved. SPDX-License-Identifier: MIT-0`)

---

## [2026-05-15] - EKS Hybrid Nodes Gateway Integration

### Added — Terraform Infrastructure
- `terraform-live/cilium.tf`: Upgraded Cilium 1.17.4 → 1.17.13-1 (ECR AWS), enabled `vtep.enabled=true`, disabled `l7Proxy=false`
- `terraform-live/vpc-cni-snat.tf`: VPC CNI SNAT exclusion for remote pod CIDR (10.200.0.0/16)
- `terraform-live/gateway-nodes.tf`: Managed node group (2× m5.large, cross-AZ, src/dst check disabled)
- `terraform-live/gateway-iam.tf`: IAM role + Pod Identity Association for Gateway route management
- `terraform-live/gateway-helm.tf`: Helm release for EKS Hybrid Nodes Gateway (oci://public.ecr.aws/eks)
- `terraform-live/tgw.tf`: Added lifecycle ignore_changes on remote pods route (Gateway owns it)

### Changed — Kubernetes Manifests
- `manifests/burst-scaling/02-hybrid-deployment.yaml`: Removed `hostNetwork: true`, changed to `dnsPolicy: ClusterFirst`, strategy RollingUpdate (maxUnavailable=0, maxSurge=1)
- `manifests/burst-scaling/07-networkpolicy.yaml`: Replaced with expanded policy targeting `tier: hybrid` pods — ingress 8000/TCP (app + monitoring namespace), egress DNS + 443/TCP + VXLAN 8472/UDP

### Added — Observability
- `manifests/burst-scaling/12-gateway-servicemonitor.yaml`: ServiceMonitor for Gateway metrics (port 10080)
- `manifests/burst-scaling/13-gateway-alerts.yaml`: PrometheusRule with HybridGatewayLeaderLost, HybridGatewayRouteUpdateFailed, HybridPodScrapeFailure alerts

### Added — Test Suite
- `tests/test_gateway_prerequisites.sh`: Validates Cilium upgrade, VTEP config, SNAT exclusion, gateway nodes
- `tests/test_gateway_connectivity.sh`: Validates Gateway pods, lease, VPC route, VTEP, migration, NetworkPolicy, KEDA, latency
- `tests/test_gateway_observability.sh`: Validates ServiceMonitor and PrometheusRule resources
- `tests/test_gateway_failover.sh`: Validates leader election failover within 10s

### Architecture
- Gateway operates active-standby (2 pods, Kubernetes Lease, ~3-5s failover)
- VXLAN tunnel (VNI 2, UDP 8472) between Gateway nodes and Hybrid Node via Transit Gateway
- Pod-to-pod connectivity: VPC pods ↔ Hybrid pods (10.200.0.0/16) transparent via Gateway
- Estimated additional cost: ~$150-170/month (2× m5.large on-demand)

### Deployment Results (applied to cluster)

| Step | Status | Details |
|------|--------|---------|
| Cilium upgrade 1.17.4 → 1.17.13-1 | ✅ | VTEP enabled, L7 proxy disabled, rolled out in 1m18s |
| VPC CNI SNAT exclusion | ✅ | AWS_VPC_K8S_CNI_EXCLUDE_SNAT_CIDRS=10.200.0.0/16 |
| Gateway node group (2× m5.large) | ✅ | ip-10-0-30-234 (AZ-a), ip-10-0-58-34 (AZ-d) |
| Gateway Helm chart | ✅ | 2 pods Running, leader election active |
| CiliumVTEPConfig | ✅ | Endpoints synced to BPF map |
| Hybrid deployment migration | ✅ | Pod IP: 10.200.0.108 (was 10.100.0.111 hostNetwork) |
| NetworkPolicy enforcement | ✅ | Unauthorized access blocked (old permissive policy removed) |
| ServiceMonitor + PrometheusRule | ✅ | Created in monitoring namespace |
| VPC→Hybrid connectivity | ✅ | Confirmed via Hybrid Nodes Gateway VXLAN tunnel (pod IP 10.200.x.x reachable from VPC) |

### Migration Notes
- Single hybrid GPU node required scale-down/scale-up (brief ~3min interruption) instead of zero-downtime rolling update
- Old NetworkPolicy `vllm-burst-scaling-netpol` deleted (was overly permissive, conflicted with new `hybrid-pod-policy`)
- VPC route table programming handled by Cilium VTEP overlay (not VPC route entries)

---

## [2026-05-13] - Fix: Cross-VPC Network Connectivity (Hybrid ↔ EKS)

### Diagnóstico

Pods no hybrid node (CIDR `10.200.0.0/25`) não conseguiam
alcançar serviços no cluster EKS (KEDA, Prometheus, CoreDNS) via TCP/UDP.
ICMP também falhava. A comunicação era 100% local (pod-to-pod no mesmo node OK)
mas cross-VPC estava completamente quebrada.

**Causa raiz**: Security Groups restritivos em ambos os lados.
- Hybrid node SG: egress limitado a portas específicas (443, 8472, 4240, 53, 80)
- EKS node SG: ingress não incluía o pod CIDR remoto (`10.200.0.0/16`)

**Validação**: Route tables, TGW e NACLs estavam corretos. O problema era exclusivamente SG.

### Fixed — Rede (Security Groups)

- **Hybrid node SG egress**: Adicionado TCP 0-65535 e UDP 0-65535 para `cluster_vpc_cidr` (`10.0.0.0/16`)
- **Hybrid node SG ingress**: Adicionado TCP 0-65535 de `cluster_vpc_cidr` (EKS → Hybrid)
- **EKS node SG ingress**: Adicionado TCP 0-65535 e UDP 0-65535 de `remote_pod_cidr` (`10.200.0.0/16`)
- **EKS node SG ingress**: Adicionado UDP 0-65535 de `hybrid_subnet_cidr` (`10.100.0.0/24`)
- **ICMP**: Liberado em ambas as direções para diagnóstico (hybrid ↔ EKS)

### Fixed — DNS

- CoreDNS (rodando nos nós EKS, ClusterIP `172.20.0.10`) não era alcançável dos pods hybrid
- **Causa**: UDP 53 egress do hybrid existia para `0.0.0.0/0`, mas o EKS node SG não aceitava UDP do CIDR `10.200.0.0/16`
- **Solução**: Regra UDP all-ports no EKS node SG para `remote_pod_cidr` e `hybrid_subnet_cidr`
- **Resultado**: `nslookup keda-operator.keda.svc.cluster.local` → resolve corretamente via CoreDNS

### Resultado dos testes pós-fix

| Teste | Status |
|-------|--------|
| Hybrid pod → KEDA operator (TCP 8080) | ✅ |
| Hybrid pod → Prometheus (TCP 9090) | ✅ |
| Hybrid pod → ClusterIP services | ✅ |
| Hybrid pod → CoreDNS (UDP 53) | ✅ |
| Hybrid pod → FQDN resolution + TCP | ✅ |
| EKS pod → Hybrid node IP (TCP 8000 vLLM) | ✅ |
| EKS pod → Hybrid node IP (ICMP) | ✅ |
| EKS pod → Hybrid pod IP (10.200.x.x) | ⚠️ Não funciona (limitação: VPC CNI não roteia para pod CIDR Cilium) |

### Changed — Terraform (`terraform/security.tf`)

Adicionados 6 novos `aws_security_group_rule` resources:
- `hybrid_node_egress_tcp_cluster`
- `hybrid_node_egress_udp_cluster`
- `hybrid_node_ingress_tcp_cluster`
- `eks_node_ingress_tcp_hybrid_pods`
- `eks_node_ingress_udp_hybrid_pods`
- `eks_node_ingress_udp_hybrid_nodes`

---

## [2026-05-13] - KAI Scheduler + GPU Fractionalization

### Added
- KAI Scheduler v0.14.2 (CNCF Sandbox, Apache 2.0)
- 3 replicas of Qwen3.6-35B-A3B-AWQ on 4x NVIDIA L4 via fractional GPU sharing
- Queue-based GPU allocation (inference queue, quota=4)
- NVIDIA GPU Operator v26.3.1 (migrated from standalone Device Plugin)
- Prometheus kube-prometheus-stack for DCGM metrics
- HAProxy Ingress Controller with internal NLB
- Route53 Private Hosted Zone `llm-k8sv4.local`
- TLS certificates (self-signed CA)
- Knative Serving v1.18.2 with Kourier
- Documentation: `docs/relatorio-kai-scheduler.md`

### Changed
- Instance type: g6.xlarge → g6.12xlarge (4x NVIDIA L4, 96GB VRAM)
- user_data: includes NVIDIA Container Toolkit installation
- VPC routes: inline → separate aws_route resources

### Fixed
- VPC Peering routes lost on terraform apply
- Mixed protocol error on NLB (removed QUIC/UDP)
- Multiple tagged SG conflict for LB controller

## [2026-05-12] - EKS Hybrid Nodes GPU POC

### Added
- Terraform: VPC, peering, SG, EC2, IAM, SSM activation
- EKS cluster: Private endpoint, RemoteNetworkConfig
- Hybrid node: NVIDIA drivers, nodeadm, cluster registration
- Cilium CNI v1.16.6 (VXLAN, IPAM cluster-pool)
- NVIDIA Device Plugin v0.17.1 + DCGM Exporter
- vLLM deployment with Qwen3.6-35B-A3B-AWQ
- Documentation: README, troubleshooting, ADRs, cleanup script
