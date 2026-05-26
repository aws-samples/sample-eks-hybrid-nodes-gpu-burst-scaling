# Cost Analysis — Hybrid Cloud Burst Scaling for vLLM Inference

This document compares the monthly cost of running a Qwen3.6-35B-A3B-AWQ
inference service on Amazon Elastic Kubernetes Service (Amazon EKS) using two strategies:

- **Always-on (Scenario A):** four `g6.12xlarge` on-demand instances sized for
  the peak load.
- **Hybrid burst (Scenario B):** one always-on `g6.12xlarge` baseline (hybrid
  node, e.g. on-premises GPU server) plus cloud burst on `g6.2xlarge` spot
  instances triggered by KEDA when latency / queue thresholds are breached.

## Assumptions

| Parameter | Value |
|---|---|
| Hours / month | 730 |
| Region | `ap-northeast-1` |
| `g6.12xlarge` on-demand | **$5.87 / hr** (4× L4) |
| `g6.2xlarge` spot | **~$0.70 / hr** (1× L4) |
| AWS Transit Gateway attachment | **$0.07 / hr / attachment** (2 attachments) |
| AWS Transit Gateway data processing | **$0.02 / GB** |
| Average concurrent burst pods when bursting | 3 |
| Hybrid pod cold start | ~2 min (model on local disk) |
| Burst pod cold start | ~4–5 min (Karpenter + Amazon Simple Storage Service (Amazon S3) streaming) |

AWS Transit Gateway fixed cost: `2 × $0.07 × 730 ≈ $102.20 / month`.

Scenario A does not need AWS Transit Gateway (single VPC, fully cloud). Scenario B includes
AWS Transit Gateway because the hybrid node lives in a separate VPC.

## Compute cost reference

| Resource | Unit cost | 730 h / month |
|---|---:|---:|
| 1× `g6.12xlarge` on-demand | $5.87 / hr | $4,285.10 |
| 4× `g6.12xlarge` on-demand | $23.48 / hr | $17,140.40 |
| 1× `g6.2xlarge` spot | $0.70 / hr | $511.00 |
| AWS Transit Gateway (2 attachments) | $0.14 / hr | $102.20 |

## Traffic patterns

Three representative monthly profiles for the burst tier:

| Pattern | Burst hours / month | Burst data egress | Description |
|---|---:|---:|---|
| Constant low | 0 | ~130 GB | Hybrid alone handles all traffic. |
| Periodic spikes | 4 h × 30 = 120 h | ~500 GB | Daily load peaks (~4 h) trigger burst. |
| Sustained high | 12 h × 30 = 360 h | ~2,000 GB | Half the day above hybrid capacity. |

Burst hours assume 3 concurrent burst pods on average while bursting.

## Scenario A — Always-on full capacity (4× g6.12xlarge)

Every traffic pattern costs the same because capacity never scales:

| Component | Monthly cost |
|---|---:|
| 4× `g6.12xlarge` on-demand | $17,140.40 |
| TGW | $0 |
| **Total** | **$17,140.40** |

## Scenario B — Hybrid burst (1× g6.12xlarge baseline + spot burst)

Cost components:

- **Baseline:** 1× `g6.12xlarge` always-on → $4,285.10
- **AWS Transit Gateway:** $102.20
- **Burst spot:** `burst_hours × 3 pods × $0.70`
- **Egress:** `GB × $0.02`

| Pattern | Baseline | AWS Transit Gateway | Burst spot | Data | **Total** | vs A |
|---|---:|---:|---:|---:|---:|---:|
| Constant low | $4,285.10 | $102.20 | $0.00 | $2.60 | **$4,389.90** | **−74%** |
| Periodic spikes (4 h/day) | $4,285.10 | $102.20 | $252.00 | $10.00 | **$4,649.30** | **−73%** |
| Sustained high (12 h/day) | $4,285.10 | $102.20 | $756.00 | $40.00 | **$5,183.30** | **−70%** |

If the hybrid baseline is treated as a sunk capex / on-prem cost (typical for
Amazon EKS Hybrid Nodes), only the cloud-side costs are incremental:

| Pattern | AWS Transit Gateway | Burst | Data | **Cloud total** | vs A |
|---|---:|---:|---:|---:|---:|
| Constant low | $102.20 | $0.00 | $2.60 | **$104.80** | **−99%** |
| Periodic spikes | $102.20 | $252.00 | $10.00 | **$364.20** | **−98%** |
| Sustained high | $102.20 | $756.00 | $40.00 | **$898.20** | **−95%** |

## Trade-offs

| Trade-off | Impact |
|---|---|
| Burst cold start (~4–5 min) | First requests after a quiet period hit hybrid only; SLO must tolerate the cold-start window or use longer KEDA `cooldownPeriod`. |
| Burst throughput per pod | Limited by `--max-num-seqs=4` and `--tensor-parallel-size=1` on `g6.2xlarge`. Ramp `maxReplicaCount` higher if peak QPS demands it. |
| Spot interruption | KEDA + Karpenter recover automatically; in-flight requests on the interrupted pod fail. Acceptable for stateless inference. |
| AWS Transit Gateway egress | $0.02/GB across VPCs; negligible at this scale but watch if response sizes grow. |
| Hybrid hardware | Capex / depreciation not included; requires on-prem GPU host or paid cloud equivalent. |

## Recommendations

| Workload profile | Recommended strategy |
|---|---|
| Constant low traffic | Hybrid only (`maxReplicaCount=0` initially); enable burst later. |
| Periodic spikes | Hybrid + burst (this design). Best ROI: ~73% savings. |
| Sustained high (>16 h/day) | Re-evaluate: dedicated cloud GPUs may beat hybrid+burst. |
| Strict latency SLO during cold start | Pre-warm one burst pod (`minReplicaCount=1`) — adds ~$511/month. |

## References

- AWS EC2 G6 pricing: <https://aws.amazon.com/ec2/instance-types/g6/>
- AWS Transit Gateway pricing: <https://aws.amazon.com/transit-gateway/pricing/>
- vLLM benchmarking: <https://docs.vllm.ai/en/latest/performance/benchmarks.html>
