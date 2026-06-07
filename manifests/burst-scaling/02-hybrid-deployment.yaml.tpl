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
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
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
          # Mirror to your private ECR for production to avoid Docker Hub rate limits.
          image: vllm/vllm-openai-cpu:latest
          args:
            - '--port=8000'
            - '--model=Qwen/Qwen2.5-1.5B-Instruct'
            - '--served-model-name=Qwen2.5-1.5B-Instruct'
            - '--dtype=bfloat16'
            - '--max-model-len=4096'
            - '--max-num-seqs=16'
            - '--trust-remote-code'
          env:
            # vLLM CPU tuning: KV cache space (GiB) in host RAM
            - name: VLLM_CPU_KVCACHE_SPACE
              value: "4"
            # Hugging Face cache on the node (model pulled at first start ~3GB)
            - name: HF_HOME
              value: /root/.cache/huggingface
          ports:
            - containerPort: 8000
              name: http
          resources:
            requests:
              cpu: "3"
              memory: 6Gi
            limits:
              cpu: "4"
              memory: 8Gi
          volumeMounts:
            - name: hf-cache
              mountPath: /root/.cache/huggingface
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
