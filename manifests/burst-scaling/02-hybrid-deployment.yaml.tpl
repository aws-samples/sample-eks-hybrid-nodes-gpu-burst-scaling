# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# This file is a Terraform template. After 'terraform apply', the rendered
# manifest is written to manifests/burst-scaling/rendered/02-hybrid-deployment.yaml
# =============================================================================
apiVersion: apps/v1
kind: Deployment
metadata:
  name: qwen36-hybrid
  labels:
    app: vllm-burst-scaling
    model: qwen36-35b-a3b
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
      model: qwen36-35b-a3b
      tier: hybrid
  template:
    metadata:
      labels:
        app: vllm-burst-scaling
        model: qwen36-35b-a3b
        tier: hybrid
    spec:
      dnsPolicy: ClusterFirst
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
      nodeSelector:
        eks.amazonaws.com/compute-type: hybrid
      containers:
        - name: vllm
          image: ${dlc_account_id}.dkr.ecr.${region}.amazonaws.com/vllm:0.19.1-gpu-py312-cu129-ubuntu22.04-ec2-v1.1-soci
          args:
            - '--port=8000'
            - '--model=/model'
            - '--served-model-name=Qwen3.6-35B-A3B-AWQ'
            - '--quantization=awq_marlin'
            - '--tensor-parallel-size=4'
            - '--gpu_memory_utilization=0.85'
            - '--max-model-len=4096'
            - '--max-num-seqs=32'
            - '--dtype=float16'
            - '--trust-remote-code'
            - '--reasoning-parser=qwen3'
            - '--enable-auto-tool-choice'
            - '--tool-call-parser=qwen3_coder'
          env:
            - name: VLLM_USE_DEEP_GEMM
              value: "0"
            - name: VLLM_USE_FLASHINFER_MOE_FP16
              value: "1"
          ports:
            - containerPort: 8000
              name: http
          resources:
            requests:
              cpu: 8
              memory: 24Gi
              nvidia.com/gpu: 4
            limits:
              cpu: 16
              memory: 48Gi
              nvidia.com/gpu: 4
          volumeMounts:
            - name: model
              mountPath: /model
              readOnly: true
          readinessProbe:
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 120
            periodSeconds: 10
            failureThreshold: 12
          livenessProbe:
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 300
            periodSeconds: 30
            failureThreshold: 5
      volumes:
        - name: model
          hostPath:
            path: /opt/models/qwen36-awq
            type: Directory
