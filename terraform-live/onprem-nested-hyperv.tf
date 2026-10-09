# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

################################################################################
# Nested Hyper-V "on-premises" (onprem_mode = "nested-hyperv")
#
# A third way to run the on-premises side, for demos and PoCs without vSphere
# hardware: an EC2 8th-gen Intel instance with NESTED VIRTUALIZATION runs Windows
# Server + Hyper-V, and an Ubuntu VM inside Hyper-V is the EKS hybrid node. The
# hybrid node therefore runs on a real hypervisor, as it would in a customer data
# center, not as an EC2 instance pretending to be one.
#
# Ported from the EKS Hybrid Nodes workshop. Layout:
#
#   EKS VPC (10.43/16) --TGW-- DC VPC (nested_dc_vpc_cidr)
#                                 |-- private subnet: Hyper-V host ENI (routes the LAN)
#                                 |      `-- DCSwitch (onprem_node_cidr): Ubuntu VM = hybrid node
#                                 `-- public subnet:  NAT gateway (internet egress for the LAN)
#
# Transport: the DC VPC is a Transit Gateway VPC attachment, not a Site-to-Site
# VPN. That keeps the demo to a single `terraform apply` with no edge appliance;
# the vSphere mode keeps the VPN path for a real site.
#
# Build time: the SSM Automation starts once the cluster exists and took 9.5 min
# end to end in us-east-1 (Hyper-V role + reboot, VM boot, nodeadm join), so it
# overlaps the rest of `terraform apply`. See docs/nested-hyperv-onprem-setup.md.
################################################################################

locals {
  nested_count = local.nested_mode ? 1 : 0

  # Hyper-V internal switch = the on-premises LAN (onprem_node_cidr)
  nested_gateway_ip  = cidrhost(var.onprem_node_cidr, 1)
  nested_vm_ip       = cidrhost(var.onprem_node_cidr, 11)
  nested_node_prefix = split("/", var.onprem_node_cidr)[1]
  nested_vm_name     = "hybrid-node-1"

  nested_image_key     = "nested/ubuntu-24.04-base.vhdx"
  nested_user_data_key = "nested/user-data"
  nested_meta_data_key = "nested/meta-data"

  # Prefer the second AZ that offers the host type: the workshop hit
  # InsufficientInstanceCapacity for m8i in us-east-1a while 1b-1f had capacity.
  nested_host_azs = local.nested_mode ? sort(data.aws_ec2_instance_type_offerings.nested_host[0].locations) : []
  nested_host_az  = local.nested_mode ? (length(local.nested_host_azs) > 1 ? local.nested_host_azs[1] : local.nested_host_azs[0]) : null
}

data "aws_ec2_instance_type_offerings" "nested_host" {
  count = local.nested_count

  location_type = "availability-zone"
  filter {
    name   = "instance-type"
    values = [var.nested_host_instance_type]
  }
}

data "aws_ssm_parameter" "windows_ami" {
  count = local.nested_count
  name  = "/aws/service/ami-windows-latest/Windows_Server-2025-English-Full-Base"
}

################################################################################
# Data center VPC
################################################################################

resource "aws_vpc" "dc" {
  count = local.nested_count

  cidr_block           = var.nested_dc_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, { Name = "${local.name}-onprem-dc" })

  lifecycle {
    precondition {
      condition     = local.nested_host_az != null
      error_message = "Instance type ${var.nested_host_instance_type} is not offered in any AZ of ${var.region}."
    }
  }
}

resource "aws_subnet" "dc_public" {
  count = local.nested_count

  vpc_id            = aws_vpc.dc[0].id
  cidr_block        = cidrsubnet(var.nested_dc_vpc_cidr, 8, 0)
  availability_zone = local.nested_host_az

  tags = merge(local.tags, { Name = "${local.name}-onprem-dc-public" })
}

resource "aws_subnet" "dc_private" {
  count = local.nested_count

  vpc_id            = aws_vpc.dc[0].id
  cidr_block        = cidrsubnet(var.nested_dc_vpc_cidr, 8, 1)
  availability_zone = local.nested_host_az

  tags = merge(local.tags, { Name = "${local.name}-onprem-dc-server-room" })
}

resource "aws_internet_gateway" "dc" {
  count  = local.nested_count
  vpc_id = aws_vpc.dc[0].id
  tags   = merge(local.tags, { Name = "${local.name}-onprem-dc" })
}

resource "aws_eip" "dc_nat" {
  count  = local.nested_count
  domain = "vpc"
  tags   = merge(local.tags, { Name = "${local.name}-onprem-dc-nat" })
}

# NAT gateways translate traffic from sources outside the VPC CIDR as well, so
# the VM keeps its LAN IP inside the data center and still reaches the internet
# (nodeadm, container images, Hugging Face).
resource "aws_nat_gateway" "dc" {
  count = local.nested_count

  allocation_id = aws_eip.dc_nat[0].id
  subnet_id     = aws_subnet.dc_public[0].id

  tags       = merge(local.tags, { Name = "${local.name}-onprem-dc" })
  depends_on = [aws_internet_gateway.dc]
}

resource "aws_route_table" "dc_public" {
  count  = local.nested_count
  vpc_id = aws_vpc.dc[0].id
  tags   = merge(local.tags, { Name = "${local.name}-onprem-dc-public" })
}

resource "aws_route_table" "dc_private" {
  count  = local.nested_count
  vpc_id = aws_vpc.dc[0].id
  tags   = merge(local.tags, { Name = "${local.name}-onprem-dc-private" })
}

resource "aws_route_table_association" "dc_public" {
  count          = local.nested_count
  subnet_id      = aws_subnet.dc_public[0].id
  route_table_id = aws_route_table.dc_public[0].id
}

resource "aws_route_table_association" "dc_private" {
  count          = local.nested_count
  subnet_id      = aws_subnet.dc_private[0].id
  route_table_id = aws_route_table.dc_private[0].id
}

resource "aws_route" "dc_public_internet" {
  count                  = local.nested_count
  route_table_id         = aws_route_table.dc_public[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.dc[0].id
}

resource "aws_route" "dc_private_internet" {
  count                  = local.nested_count
  route_table_id         = aws_route_table.dc_private[0].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.dc[0].id
}

resource "aws_route" "dc_private_to_eks" {
  count                  = local.nested_count
  route_table_id         = aws_route_table.dc_private[0].id
  destination_cidr_block = local.vpc_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.main.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.dc]
}

# The LAN and the remote pod CIDR live BEHIND the Hyper-V host. Both route tables
# need them: the private one for traffic arriving from the TGW, the public one
# for the NAT gateway's return traffic. Missing the public pair means internet
# egress leaves and never comes back.
resource "aws_route" "dc_lan_via_host" {
  for_each = local.nested_mode ? {
    private-nodes = { rt = aws_route_table.dc_private[0].id, cidr = var.onprem_node_cidr }
    private-pods  = { rt = aws_route_table.dc_private[0].id, cidr = var.remote_pod_cidr }
    public-nodes  = { rt = aws_route_table.dc_public[0].id, cidr = var.onprem_node_cidr }
    public-pods   = { rt = aws_route_table.dc_public[0].id, cidr = var.remote_pod_cidr }
  } : {}

  route_table_id         = each.value.rt
  destination_cidr_block = each.value.cidr
  network_interface_id   = aws_network_interface.nested_host[0].id
}

################################################################################
# Transit Gateway: attach the DC VPC and route the on-premises CIDRs to it
################################################################################

resource "aws_ec2_transit_gateway_vpc_attachment" "dc" {
  count = local.nested_count

  subnet_ids         = [aws_subnet.dc_private[0].id]
  transit_gateway_id = aws_ec2_transit_gateway.main.id
  vpc_id             = aws_vpc.dc[0].id

  tags = merge(local.tags, { Name = "${local.name}-tgw-onprem-dc" })
}

resource "aws_ec2_transit_gateway_route" "onprem_cidrs" {
  for_each = local.nested_mode ? { nodes = var.onprem_node_cidr, pods = var.remote_pod_cidr } : {}

  destination_cidr_block         = each.value
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.dc[0].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway.main.association_default_route_table_id
}

################################################################################
# Hyper-V host
################################################################################

resource "aws_security_group" "nested_host" {
  count = local.nested_count

  name_prefix = "${local.name}-hyperv-host-"
  description = "Hyper-V host - forwards data center traffic to the nested hybrid node VM"
  vpc_id      = aws_vpc.dc[0].id

  ingress {
    description = "EKS VPC (control plane to kubelet, Hybrid Nodes Gateway VXLAN, cloud pods)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [local.vpc_cidr]
  }

  ingress {
    description = "Data center VPC and the nested LAN/pod networks"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.nested_dc_vpc_cidr, var.onprem_node_cidr, var.remote_pod_cidr]
  }

  egress {
    description = "All outbound (SSM, S3, internet via NAT, EKS)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${local.name}-hyperv-host" })

  lifecycle {
    create_before_destroy = true
  }
}

# source/dest check OFF: the host forwards packets for the nested LAN
resource "aws_network_interface" "nested_host" {
  count = local.nested_count

  subnet_id         = aws_subnet.dc_private[0].id
  security_groups   = [aws_security_group.nested_host[0].id]
  source_dest_check = false

  tags = merge(local.tags, { Name = "${local.name}-hyperv-host" })
}

resource "aws_iam_role" "nested_host" {
  count = local.nested_count
  name  = "${local.name}-hyperv-host"

  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "nested_host_ssm" {
  count      = local.nested_count
  role       = aws_iam_role.nested_host[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "nested_host_artifacts" {
  count = local.nested_count
  name  = "read-nested-artifacts"
  role  = aws_iam_role.nested_host[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = "${aws_s3_bucket.nested_artifacts[0].arn}/nested/*"
    }]
  })
}

resource "aws_iam_instance_profile" "nested_host" {
  count = local.nested_count
  name  = "${local.name}-hyperv-host"
  role  = aws_iam_role.nested_host[0].name
}

# The Terraform AWS provider exposes cpu_options.nested_virtualization only from
# v6.33, and this sample pins ~> 5.85 (EKS module v20). Until the sample moves to
# provider 6.x, the launch template and the instance come from this minimal
# CloudFormation stack, which supports NestedVirtualization on
# AWS::EC2::LaunchTemplate. Everything around it stays in Terraform.
resource "aws_cloudformation_stack" "nested_host" {
  count = local.nested_count
  name  = "${local.name}-hyperv-host"

  template_body = jsonencode({
    AWSTemplateFormatVersion = "2010-09-09"
    Description              = "Hyper-V host with nested virtualization (EKS Hybrid Nodes GPU burst sample, managed by Terraform)"
    Resources = {
      LaunchTemplate = {
        Type = "AWS::EC2::LaunchTemplate"
        Properties = {
          LaunchTemplateData = {
            ImageId            = data.aws_ssm_parameter.windows_ami[0].value
            InstanceType       = var.nested_host_instance_type
            CpuOptions         = { NestedVirtualization = "enabled" }
            IamInstanceProfile = { Arn = aws_iam_instance_profile.nested_host[0].arn }
            MetadataOptions    = { HttpEndpoint = "enabled", HttpTokens = "required", HttpPutResponseHopLimit = 2 }
            BlockDeviceMappings = [{
              DeviceName = "/dev/sda1"
              Ebs        = { VolumeSize = 150, VolumeType = "gp3", Encrypted = true, DeleteOnTermination = true }
            }]
          }
        }
      }
      Host = {
        Type = "AWS::EC2::Instance"
        Properties = {
          LaunchTemplate    = { LaunchTemplateId = { Ref = "LaunchTemplate" }, Version = { "Fn::GetAtt" = ["LaunchTemplate", "LatestVersionNumber"] } }
          NetworkInterfaces = [{ NetworkInterfaceId = aws_network_interface.nested_host[0].id, DeviceIndex = "0" }]
          Tags = [
            { Key = "Name", Value = "${local.name}-hyperv-host (on-premises server)" },
            { Key = "Project", Value = var.cluster_name },
          ]
        }
      }
    }
    Outputs = {
      InstanceId = { Value = { Ref = "Host" } }
    }
  })

  tags = local.tags

  depends_on = [aws_iam_role_policy_attachment.nested_host_ssm]
}

################################################################################
# Artifacts: VM seed (cloud-init) and the converted Ubuntu VHDX
################################################################################

resource "aws_s3_bucket" "nested_artifacts" {
  count = local.nested_count

  bucket_prefix = "${lower(substr(local.name, 0, 24))}-nested-"
  force_destroy = true

  tags = local.tags
}

resource "aws_s3_bucket_public_access_block" "nested_artifacts" {
  count = local.nested_count

  bucket                  = aws_s3_bucket.nested_artifacts[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "nested_artifacts" {
  count  = local.nested_count
  bucket = aws_s3_bucket.nested_artifacts[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_policy" "nested_artifacts_tls" {
  count  = local.nested_count
  bucket = aws_s3_bucket.nested_artifacts[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.nested_artifacts[0].arn, "${aws_s3_bucket.nested_artifacts[0].arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.nested_artifacts]
}

# The seed carries the SSM activation code, so it lives only in this private,
# TLS-only bucket and is readable only by the Hyper-V host role.
resource "aws_s3_object" "nested_user_data" {
  count = local.nested_count

  bucket = aws_s3_bucket.nested_artifacts[0].id
  key    = local.nested_user_data_key
  content = sensitive(templatefile("${path.module}/templates/nested-node-user-data.yaml.tpl", {
    vm_name         = local.nested_vm_name
    vm_ip           = local.nested_vm_ip
    node_prefix     = local.nested_node_prefix
    gateway_ip      = local.nested_gateway_ip
    cluster_name    = module.eks.cluster_name
    region          = var.region
    k8s_version     = module.eks.cluster_version
    activation_id   = aws_ssm_activation.hybrid_node.id
    activation_code = aws_ssm_activation.hybrid_node.activation_code
  }))

  depends_on = [aws_s3_bucket_policy.nested_artifacts_tls]
}

resource "aws_s3_object" "nested_meta_data" {
  count = local.nested_count

  bucket  = aws_s3_bucket.nested_artifacts[0].id
  key     = local.nested_meta_data_key
  content = "instance-id: ${local.nested_vm_name}\nlocal-hostname: ${local.nested_vm_name}\n"

  depends_on = [aws_s3_bucket_policy.nested_artifacts_tls]
}

# qcow2 -> VHDX in CodeBuild (Amazon Linux qemu-img). Windows has no native
# qcow2 tooling; the workshop does this on its IDE instance, which this sample
# does not have. Idempotent: an existing VHDX is reused.
resource "aws_cloudwatch_log_group" "nested_image" {
  count             = local.nested_count
  name              = "/aws/codebuild/${local.name}-hyperv-image"
  retention_in_days = 7
  tags              = local.tags
}

resource "aws_iam_role" "nested_image" {
  count = local.nested_count
  name  = "${local.name}-hyperv-image"

  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "codebuild.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "nested_image" {
  count = local.nested_count
  name  = "convert-ubuntu-image"
  role  = aws_iam_role.nested_image[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.nested_image[0].arn}:*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = "${aws_s3_bucket.nested_artifacts[0].arn}/${local.nested_image_key}"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.nested_artifacts[0].arn
      },
    ]
  })
}

resource "aws_codebuild_project" "nested_image" {
  count = local.nested_count

  name          = "${local.name}-hyperv-image"
  description   = "Convert the Ubuntu cloud image to VHDX for the nested Hyper-V hybrid node"
  service_role  = aws_iam_role.nested_image[0].arn
  build_timeout = 30

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    type         = "LINUX_CONTAINER"
    compute_type = "BUILD_GENERAL1_MEDIUM"
    image        = "aws/codebuild/amazonlinux-x86_64-standard:5.0"
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.nested_image[0].name
    }
  }

  source {
    type      = "NO_SOURCE"
    buildspec = <<-EOT
      version: 0.2
      env:
        variables:
          BUCKET: "${aws_s3_bucket.nested_artifacts[0].id}"
          KEY: "${local.nested_image_key}"
          IMAGE_URL: "${var.nested_ubuntu_image_url}"
      phases:
        build:
          commands:
            - |
              set -euo pipefail
              if aws s3api head-object --bucket "$BUCKET" --key "$KEY" >/dev/null 2>&1; then
                echo "VHDX already in s3://$BUCKET/$KEY - reusing it"
              else
                dnf install -y -q qemu-img
                curl -fL --retry 3 --connect-timeout 20 "$IMAGE_URL" -o /tmp/ubuntu.img
                qemu-img convert -f qcow2 -O vhdx -o subformat=dynamic /tmp/ubuntu.img /tmp/ubuntu-base.vhdx
                SIZE=$(stat -c %s /tmp/ubuntu-base.vhdx)
                [ "$SIZE" -ge 500000000 ] || { echo "converted VHDX too small: $SIZE bytes"; exit 1; }
                aws s3 cp /tmp/ubuntu-base.vhdx "s3://$BUCKET/$KEY" --only-show-errors
                REMOTE=$(aws s3api head-object --bucket "$BUCKET" --key "$KEY" --query ContentLength --output text)
                [ "$REMOTE" = "$SIZE" ] || { echo "S3 size mismatch: local=$SIZE remote=$REMOTE"; exit 1; }
                echo "VHDX_READY: s3://$BUCKET/$KEY ($REMOTE bytes)"
              fi
    EOT
  }

  tags = local.tags
}

################################################################################
# SSM Automation: Hyper-V role, data center LAN, VM build and node join
################################################################################

resource "aws_ssm_document" "nested_setup" {
  count = local.nested_count

  name            = "${local.name}-hyperv-setup"
  document_type   = "Automation"
  document_format = "YAML"
  content = templatefile("${path.module}/templates/nested-hyperv-setup.yaml.tpl", {
    codebuild_project = aws_codebuild_project.nested_image[0].name
    bucket            = aws_s3_bucket.nested_artifacts[0].id
    image_key         = local.nested_image_key
    user_data_key     = local.nested_user_data_key
    meta_data_key     = local.nested_meta_data_key
    gateway_ip        = local.nested_gateway_ip
    node_prefix       = local.nested_node_prefix
    vm_name           = local.nested_vm_name
    vm_ip             = local.nested_vm_ip
    vm_vcpus          = var.nested_vm_vcpus
    vm_memory_gb      = var.nested_vm_memory_gb
    vm_disk_gb        = var.nested_vm_disk_gb
    pod_net           = cidrhost(var.remote_pod_cidr, 0)
    pod_mask          = cidrnetmask(var.remote_pod_cidr)
    activation_id     = aws_ssm_activation.hybrid_node.id
  })

  tags = local.tags
}

resource "aws_iam_role" "nested_automation" {
  count = local.nested_count
  name  = "${local.name}-hyperv-automation"

  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ssm.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "nested_automation" {
  count = local.nested_count
  name  = "hyperv-setup"
  role  = aws_iam_role.nested_automation[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # read/list APIs without resource-level permissions
        Effect   = "Allow"
        Action   = ["ssm:DescribeInstanceInformation", "ssm:GetCommandInvocation", "ssm:ListCommands", "ssm:ListCommandInvocations", "ec2:DescribeInstances"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = ["ssm:SendCommand"]
        Resource = [
          "arn:aws:ssm:${var.region}::document/AWS-RunPowerShellScript",
          "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:instance/${aws_cloudformation_stack.nested_host[0].outputs["InstanceId"]}",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:RebootInstances"]
        Resource = "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:instance/${aws_cloudformation_stack.nested_host[0].outputs["InstanceId"]}"
      },
      {
        Effect   = "Allow"
        Action   = ["codebuild:StartBuild", "codebuild:BatchGetBuilds"]
        Resource = aws_codebuild_project.nested_image[0].arn
      },
    ]
  })
}

# No schedule: runs once, as soon as it is created. The first step waits for the
# Windows host to register with SSM, so creation order does not matter.
resource "aws_ssm_association" "nested_setup" {
  count = local.nested_count

  association_name                 = "${local.name}-hyperv-setup"
  name                             = aws_ssm_document.nested_setup[0].name
  automation_target_parameter_name = "InstanceId"

  targets {
    key    = "ParameterValues"
    values = [aws_cloudformation_stack.nested_host[0].outputs["InstanceId"]]
  }

  parameters = {
    AutomationAssumeRole = aws_iam_role.nested_automation[0].arn
  }

  depends_on = [
    aws_iam_role_policy.nested_automation,
    aws_iam_role_policy.nested_host_artifacts,
    aws_iam_role_policy.nested_image,
    aws_s3_object.nested_user_data,
    aws_s3_object.nested_meta_data,
    aws_route.dc_lan_via_host,
    aws_route.dc_private_internet,
    aws_route.dc_public_internet,
    aws_ec2_transit_gateway_route.onprem_cidrs,
    module.eks,
  ]
}
