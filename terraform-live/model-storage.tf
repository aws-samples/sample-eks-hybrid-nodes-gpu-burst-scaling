# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

################################################################################
# S3 Bucket for Model Storage
################################################################################

resource "aws_s3_bucket" "model_storage" {
  bucket = "vllm-qwen35b-models-${data.aws_caller_identity.current.account_id}"

  tags = merge(local.tags, {
    Name = "vllm-qwen35b-models"
  })
}

resource "aws_s3_bucket_versioning" "model_storage" {
  bucket = aws_s3_bucket.model_storage.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "model_storage" {
  bucket = aws_s3_bucket.model_storage.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket" "model_storage_logs" {
  bucket = "vllm-qwen35b-models-${data.aws_caller_identity.current.account_id}-logs"

  tags = merge(local.tags, {
    Name = "vllm-qwen35b-models-logs"
  })
}

resource "aws_s3_bucket_public_access_block" "model_storage_logs" {
  bucket                  = aws_s3_bucket.model_storage_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_logging" "model_storage" {
  bucket = aws_s3_bucket.model_storage.id

  target_bucket = aws_s3_bucket.model_storage_logs.id
  target_prefix = "access-logs/"
}

resource "aws_s3_bucket_public_access_block" "model_storage" {
  bucket                  = aws_s3_bucket.model_storage.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "model_storage_tls" {
  bucket = aws_s3_bucket.model_storage.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.model_storage.arn,
        "${aws_s3_bucket.model_storage.arn}/*"
      ]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.model_storage]
}

################################################################################
# IRSA for model-storage-sa ServiceAccount (S3 read/write)
################################################################################

module "model_storage_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.52.2"

  role_name = "${local.name}-model-storage"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["default:model-storage-sa"]
    }
  }

  role_policy_arns = {
    model_storage = aws_iam_policy.model_storage.arn
  }

  tags = local.tags
}

resource "aws_iam_policy" "model_storage" {
  name        = "${local.name}-model-storage"
  description = "S3 access for model download and upload"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket",
          "s3:DeleteObject"
        ]
        Resource = [
          aws_s3_bucket.model_storage.arn,
          "${aws_s3_bucket.model_storage.arn}/*"
        ]
      }
    ]
  })
}

################################################################################
# Kubernetes ServiceAccount with IRSA annotation
################################################################################

resource "kubectl_manifest" "model_storage_sa" {
  yaml_body = <<-YAML
    apiVersion: v1
    kind: ServiceAccount
    metadata:
      name: model-storage-sa
      namespace: default
      annotations:
        eks.amazonaws.com/role-arn: ${module.model_storage_irsa.iam_role_arn}
  YAML

  depends_on = [module.eks, module.model_storage_irsa]
}

################################################################################
# Job 1: Download model from HuggingFace → S3
################################################################################

resource "kubectl_manifest" "download_model_to_s3" {
  yaml_body = <<-YAML
    apiVersion: batch/v1
    kind: Job
    metadata:
      name: download-model-to-s3
      labels:
        app: model-downloader
        phase: huggingface-to-s3
    spec:
      backoffLimit: 3
      ttlSecondsAfterFinished: 3600
      template:
        metadata:
          labels:
            app: model-downloader
        spec:
          serviceAccountName: model-storage-sa
          restartPolicy: OnFailure
          terminationGracePeriodSeconds: 10
          containers:
            - name: downloader
              image: python:3.11-slim
              command: ["/bin/bash", "-c"]
              args:
                - |
                  set -eux
                  pip install -q huggingface_hub awscli
                  # Check if model already in S3
                  if aws s3 ls s3://${aws_s3_bucket.model_storage.id}/Qwen3.6-35B-A3B-AWQ/config.json 2>/dev/null; then
                    echo "Model already exists in S3 — skipping download"
                    exit 0
                  fi
                  echo "=== Downloading model from HuggingFace ==="
                  python -c "
                  from huggingface_hub import snapshot_download
                  snapshot_download(
                      repo_id='Chunity/Qwen3.6-35B-A3B-AutoRound-AWQ-4bit',
                      local_dir='/tmp/model',
                      ignore_patterns=['*.md', '*.txt', '.gitattributes']
                  )
                  "
                  echo "=== Uploading to S3 ==="
                  aws s3 sync /tmp/model s3://${aws_s3_bucket.model_storage.id}/Qwen3.6-35B-A3B-AWQ/ \
                    --region ${var.region}
                  echo "=== DONE ==="
              resources:
                requests:
                  cpu: 2
                  memory: 4Gi
                  ephemeral-storage: 25Gi
                limits:
                  cpu: 4
                  memory: 8Gi
                  ephemeral-storage: 30Gi
  YAML

  depends_on = [
    kubectl_manifest.model_storage_sa,
    aws_s3_bucket.model_storage,
    module.eks.eks_managed_node_groups
  ]
}

################################################################################
# Job 2: Download model from S3 → Hybrid Node hostPath
# 
# NOTA: Este Job tem nodeSelector hybrid e só roda quando:
#   1. O hybrid node está Ready (Cilium CNI funcionando)
#   2. O modelo já está no S3 (Job 1 completou)
#
# O Terraform NÃO espera o Job completar (kubectl_manifest apenas cria o recurso).
# O Job ficará Pending até o hybrid node estar Ready, depois executa automaticamente.
# Use `kubectl get jobs -w` para acompanhar.
################################################################################

resource "kubectl_manifest" "download_model_to_hostpath" {
  yaml_body = <<-YAML
    apiVersion: batch/v1
    kind: Job
    metadata:
      name: download-model-to-hostpath
      labels:
        app: model-downloader
        phase: s3-to-hostpath
    spec:
      backoffLimit: 10
      ttlSecondsAfterFinished: 7200
      template:
        metadata:
          labels:
            app: model-downloader
        spec:
          serviceAccountName: model-storage-sa
          restartPolicy: OnFailure
          dnsPolicy: Default
          tolerations:
            - effect: NoSchedule
              key: nvidia.com/gpu
              operator: Exists
          nodeSelector:
            eks.amazonaws.com/compute-type: hybrid
          containers:
            - name: downloader
              image: amazon/aws-cli:latest
              command: ["sh", "-c"]
              args:
                - |
                  set -eux
                  echo "Downloading Qwen3.6 AWQ from S3 to hostPath..."
                  aws s3 sync s3://${aws_s3_bucket.model_storage.id}/Qwen3.6-35B-A3B-AWQ/ /model/ \
                    --region ${var.region}
                  echo "Download complete:"
                  du -sh /model/
                  ls /model/
              env:
                - name: AWS_DEFAULT_REGION
                  value: "${var.region}"
              volumeMounts:
                - name: model-host
                  mountPath: /model
              resources:
                requests:
                  cpu: "1"
                  memory: 1Gi
                limits:
                  cpu: "2"
                  memory: 2Gi
          volumes:
            - name: model-host
              hostPath:
                path: /opt/models/qwen-model
                type: DirectoryOrCreate
  YAML

  depends_on = [
    kubectl_manifest.download_model_to_s3,
    kubectl_manifest.model_storage_sa,
    helm_release.cilium,
    helm_release.gpu_operator
  ]
}
