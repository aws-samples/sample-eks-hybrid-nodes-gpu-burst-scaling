# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

################################################################################
# EC2 Hybrid GPU Node
################################################################################

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "tls_private_key" "hybrid_node" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "hybrid_node" {
  key_name   = "${local.name}-hybrid-node"
  public_key = tls_private_key.hybrid_node.public_key_openssh
}

resource "local_file" "hybrid_node_private_key" {
  content         = tls_private_key.hybrid_node.private_key_pem
  filename        = "${path.module}/${local.name}-hybrid-node.pem"
  file_permission = "0600"
}

resource "aws_instance" "hybrid_gpu_node" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.hybrid_node.key_name
  subnet_id              = aws_subnet.hybrid_private.id
  vpc_security_group_ids = [aws_security_group.hybrid_node.id]
  iam_instance_profile   = aws_iam_instance_profile.hybrid_node_ec2.name
  ebs_optimized          = true # CKV_AWS_135: EBS optimized (no extra cost for modern instance types)

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size           = 500
    volume_type           = "gp3"
    iops                  = 16000
    throughput            = 1000
    delete_on_termination = true
    encrypted             = true
  }

  user_data = base64encode(templatefile("${path.module}/templates/hybrid-node-userdata.sh.tpl", {
    cluster_name    = var.cluster_name
    region          = var.region
    activation_id   = aws_ssm_activation.hybrid_node.id
    activation_code = aws_ssm_activation.hybrid_node.activation_code
  }))

  tags = merge(local.tags, {
    Name = "${local.name}-hybrid-gpu-node"
    Role = "hybrid-node"
  })

  depends_on = [
    aws_nat_gateway.hybrid,
    aws_ssm_activation.hybrid_node
  ]
}
