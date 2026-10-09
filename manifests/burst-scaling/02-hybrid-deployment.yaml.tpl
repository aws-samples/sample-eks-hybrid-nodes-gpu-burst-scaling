# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# This file is a Terraform template. After 'terraform apply', the rendered
# manifest is written to manifests/burst-scaling/rendered/02-hybrid-deployment.yaml
#
# BASELINE (on-premises, CPU) — VMware vSphere flavor.
# Runs Qwen2.5-1.5B-Instruct on CPU on the on-premises hybrid node. No GPU
# on-premises. When this baseline saturates, KEDA + Karpenter burst the larger
# model on GPU spot nodes in the cloud (see 03-burst-deployment).
# =============================================================================
apiVersion: apps/v1
kind: Deployment
metadata:
  name: qwen-hybrid
  labels:
    app: vllm-burst-scaling
    model: qwen25-1-5b
    tier: hybrid
spec:
  replicas: 1
  strategy:
    # One hybrid node holds one baseline copy (~8 GiB). Surging a second copy
    # onto the same node evicts both under memory pressure, so replace instead.
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1
      maxSurge: 0
  selector:
    matchLabels:
      model: qwen25-1-5b
      tier: hybrid
  template:
    metadata:
      labels:
        app: vllm-burst-scaling
        model: qwen25-1-5b
        tier: hybrid
    spec:
      dnsPolicy: ClusterFirst
      # Pin the baseline to the on-premises hybrid node (CPU). No GPU toleration.
      nodeSelector:
        eks.amazonaws.com/compute-type: hybrid
      containers:
        - name: vllm
          # Official vLLM CPU image (OpenAI-compatible server, CPU build).
          # PINNED: the requests/limits below were sized on v0.22.1 (the :latest of
          # 2026-06-07). :latest drifted to v0.31.0, whose engine needs ~8 GiB for
          # this model and gets OOMKilled at the 5Gi limit. Re-measure before bumping.
          # Mirror to your private ECR for production to avoid Docker Hub rate limits.
          image: vllm/vllm-openai-cpu:v0.22.1
          args:
            - '--port=8000'
            - '--model=Qwen/Qwen2.5-1.5B-Instruct'
            - '--served-model-name=Qwen2.5-1.5B-Instruct'
            - '--dtype=bfloat16'
            - '--max-model-len=4096'
            - '--max-num-seqs=16'
            - '--trust-remote-code'
          env:
            # vLLM CPU tuning: KV cache space (GiB) in host RAM. 2 GiB of KV cache
            # (~75k tokens) is part of the ~8 GiB measured below; the node needs
            # 12 GB RAM so kubelet, Cilium and the OS fit next to it.
            - name: VLLM_CPU_KVCACHE_SPACE
              value: "2"
            # Hugging Face cache on the node (model pulled at first start ~3GB)
            - name: HF_HOME
              value: /root/.cache/huggingface
          ports:
            - containerPort: 8000
              name: http
          resources:
            # Measured 2026-10-08 on v0.22.1 (and v0.31.0): ~8.0 GiB anonymous
            # memory once the engine is up (peak 8.3 GB). The previous 5Gi limit
            # was OOMKilled right after the weights loaded.
            requests:
              cpu: "2"
              memory: 8Gi
            limits:
              cpu: "3500m"
              memory: 10Gi
          volumeMounts:
            - name: hf-cache
              mountPath: /root/.cache/huggingface
            - name: dshm
              mountPath: /dev/shm
          readinessProbe:
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 90
            periodSeconds: 10
            failureThreshold: 18
          livenessProbe:
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 180
            periodSeconds: 30
            failureThreshold: 5
      volumes:
        # Model cache on the node's local disk (persists across pod restarts).
        - name: hf-cache
          hostPath:
            path: /opt/models/hf-cache
            type: DirectoryOrCreate
        # vLLM >= 0.31 needs ~160 MiB of shared memory for its engine message
        # queue and refuses to start on the container default of 64 MiB
        # ("Insufficient space in /dev/shm"). Counts against the memory limit.
        - name: dshm
          emptyDir:
            medium: Memory
            sizeLimit: 512Mi
