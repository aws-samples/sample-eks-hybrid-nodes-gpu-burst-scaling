# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# This file is a Terraform template. After 'terraform apply', the rendered
# manifest is written to manifests/burst-scaling/rendered/03-burst-deployment.yaml
# =============================================================================
apiVersion: apps/v1
kind: Deployment
metadata:
  name: qwen36-burst
  labels:
    app: vllm-burst-scaling
    model: qwen36-35b-a3b
    tier: burst
spec:
  replicas: 0
  selector:
    matchLabels:
      model: qwen36-35b-a3b
      tier: burst
  template:
    metadata:
      labels:
        app: vllm-burst-scaling
        model: qwen36-35b-a3b
        tier: burst
    spec:
      serviceAccountName: model-storage-sa
      terminationGracePeriodSeconds: 90
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
      nodeSelector:
        karpenter.sh/nodepool: gpu
      containers:
        - name: vllm
          image: ${dlc_account_id}.dkr.ecr.${region}.amazonaws.com/vllm:0.19.1-gpu-py312-cu129-ubuntu22.04-ec2-v1.1-soci
          args:
            - '--port=8000'
            - '--model=s3://${model_bucket}/Qwen3.6-35B-A3B-AWQ/'
            - '--served-model-name=Qwen3.6-35B-A3B-AWQ'
            - '--load-format=runai_streamer'
            - '--model-loader-extra-config={"concurrency":4}'
            - '--quantization=awq_marlin'
            - '--tensor-parallel-size=1'
            - '--gpu_memory_utilization=0.95'
            - '--max-model-len=2048'
            - '--max-num-seqs=2'
            - '--dtype=float16'
            - '--enforce-eager'
            - '--trust-remote-code'
            - '--reasoning-parser=qwen3'
            - '--enable-auto-tool-choice'
            - '--tool-call-parser=qwen3_coder'
            - '--limit-mm-per-prompt={"image":0,"video":0}'
          env:
            - name: VLLM_USE_DEEP_GEMM
              value: "0"
            - name: VLLM_USE_FLASHINFER_MOE_FP16
              value: "1"
            - name: AWS_DEFAULT_REGION
              value: ${region}
          ports:
            - containerPort: 8000
              name: http
          resources:
            requests:
              cpu: 4
              memory: 16Gi
              nvidia.com/gpu: 1
            limits:
              cpu: 8
              memory: 48Gi
              nvidia.com/gpu: 1
          startupProbe:
            httpGet:
              path: /health
              port: 8000
            periodSeconds: 10
            failureThreshold: 30
          readinessProbe:
            httpGet:
              path: /health
              port: 8000
            periodSeconds: 10
            failureThreshold: 6
          livenessProbe:
            httpGet:
              path: /health
              port: 8000
            periodSeconds: 30
            failureThreshold: 5
