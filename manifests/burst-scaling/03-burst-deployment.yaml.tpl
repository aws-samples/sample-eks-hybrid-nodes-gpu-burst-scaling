# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# This file is a Terraform template. After 'terraform apply', the rendered
# manifest is written to manifests/burst-scaling/rendered/03-burst-deployment.yaml
# =============================================================================
apiVersion: apps/v1
kind: Deployment
metadata:
  name: qwen-burst
  labels:
    app: vllm-burst-scaling
    model: qwen25-1-5b
    tier: burst
spec:
  replicas: 0
  selector:
    matchLabels:
      model: qwen25-1-5b
      tier: burst
  template:
    metadata:
      labels:
        app: vllm-burst-scaling
        model: qwen25-1-5b
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
          # GPU vLLM image for burst pods (Karpenter provisions GPU spot nodes).
          image: ${dlc_account_id}.dkr.ecr.${region}.amazonaws.com/vllm:0.19.1-gpu-py312-cu129-ubuntu22.04-ec2-v1.1-soci
          args:
            - '--port=8000'
            # TODO(fernasch-decision): model for the burst tier.
            # Pending Fernando's input (Slack 2026-06-06): same model as the
            # CPU baseline (Qwen2.5-1.5B) to keep the Service round-robin
            # coherent, OR a larger model for asymmetric burst. Default below
            # assumes SAME model as baseline. The served-model-name MUST match
            # the baseline (02-hybrid-deployment) regardless of the choice.
            - '--model=Qwen/Qwen2.5-1.5B-Instruct'
            - '--served-model-name=Qwen2.5-1.5B-Instruct'
            - '--tensor-parallel-size=1'
            - '--gpu_memory_utilization=0.90'
            - '--max-model-len=4096'
            - '--max-num-seqs=32'
            - '--dtype=bfloat16'
            - '--trust-remote-code'
          env:
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
