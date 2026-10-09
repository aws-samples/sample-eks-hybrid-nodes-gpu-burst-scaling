# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# SSM Automation that turns the nested-virtualization EC2 host into a small
# "data center": Hyper-V role, an internal switch acting as the on-premises LAN,
# and one Ubuntu VM that self-joins the EKS cluster as a hybrid node.
# Ported from the EKS Hybrid Nodes workshop (Hyper-V host template). Rendered by
# terraform-live/onprem-nested-hyperv.tf - do not add "$" + "{" sequences to the
# PowerShell below, Terraform would try to interpolate them.
schemaVersion: '0.3'
description: Build the nested Hyper-V data center and the hybrid node VM (EKS Hybrid Nodes GPU burst sample)
assumeRole: '{{ AutomationAssumeRole }}'
parameters:
  InstanceId:
    type: String
    description: Hyper-V host instance ID (NestedVirtualization=enabled)
  AutomationAssumeRole:
    type: String
mainSteps:
  # The association starts this the moment Terraform creates it, which is
  # usually before Windows has registered with SSM. Poll instead of failing:
  # for a not-yet-registered instance the API can return an empty list OR an
  # error, so a plain waitForAwsResourceProperty is not enough here.
  - name: WaitHostOnline
    action: aws:executeScript
    maxAttempts: 3
    timeoutSeconds: 600
    inputs:
      Runtime: python3.12
      Handler: handler
      InputPayload:
        InstanceId: '{{ InstanceId }}'
      Script: |
        import time, boto3
        def handler(events, context):
            ssm = boto3.client('ssm')
            iid = events['InstanceId']
            deadline = time.time() + 540
            while time.time() < deadline:
                try:
                    info = ssm.describe_instance_information(
                        Filters=[{'Key': 'InstanceIds', 'Values': [iid]}])['InstanceInformationList']
                    if info and info[0].get('PingStatus') == 'Online':
                        return {'status': 'Online'}
                except Exception as e:
                    print('not registered yet:', e)
                time.sleep(20)
            raise Exception(iid + ' not Online in SSM yet')

  # The qcow2 -> VHDX conversion runs in CodeBuild (Amazon Linux qemu-img) in
  # parallel with the Hyper-V install. Windows has no native qcow2 tooling.
  - name: StartImageBuild
    action: aws:executeAwsApi
    inputs:
      Service: codebuild
      Api: StartBuild
      projectName: ${codebuild_project}
    outputs:
      - Name: BuildId
        Selector: $.build.id
        Type: String

  - name: InstallHyperV
    action: aws:runCommand
    timeoutSeconds: 900
    inputs:
      DocumentName: AWS-RunPowerShellScript
      InstanceIds: ['{{ InstanceId }}']
      Parameters:
        commands:
          - Install-WindowsFeature -Name Hyper-V -IncludeManagementTools | Out-String

  - name: CheckHypervisor
    action: aws:runCommand
    maxAttempts: 3
    timeoutSeconds: 300
    inputs:
      DocumentName: AWS-RunPowerShellScript
      InstanceIds: ['{{ InstanceId }}']
      Parameters:
        commands:
          - |
            $s = Get-Service vmms -ErrorAction SilentlyContinue
            if ($s -and $s.Status -eq 'Running') { Write-Output 'HYPERVISOR_LIVE' } else { Write-Output 'HYPERVISOR_NEEDS_REBOOT' }
    nextStep: BranchHypervisor

  - name: BranchHypervisor
    action: aws:branch
    inputs:
      Choices:
        - NextStep: CreateDcNetwork
          Variable: '{{ CheckHypervisor.Output }}'
          Contains: HYPERVISOR_LIVE
      Default: Reboot

  - name: Reboot
    action: aws:executeAwsApi
    inputs:
      Service: ec2
      Api: RebootInstances
      InstanceIds: ['{{ InstanceId }}']

  - name: WaitRebootStart
    action: aws:sleep
    inputs:
      Duration: PT90S

  - name: WaitSsmOnline
    action: aws:waitForAwsResourceProperty
    timeoutSeconds: 900
    inputs:
      Service: ssm
      Api: DescribeInstanceInformation
      Filters:
        - Key: InstanceIds
          Values: ['{{ InstanceId }}']
      PropertySelector: $.InstanceInformationList[0].PingStatus
      DesiredValues: [Online]

  - name: VerifyHyperV
    action: aws:runCommand
    maxAttempts: 3
    timeoutSeconds: 600
    inputs:
      DocumentName: AWS-RunPowerShellScript
      InstanceIds: ['{{ InstanceId }}']
      Parameters:
        commands:
          - |
            $deadline = (Get-Date).AddMinutes(5)
            do {
              $vmms = Get-Service vmms -ErrorAction SilentlyContinue
              if ($vmms -and $vmms.Status -eq 'Running') { break }
              Start-Sleep -Seconds 15
            } while ((Get-Date) -lt $deadline)
            if (-not $vmms -or $vmms.Status -ne 'Running') { throw 'vmms not running 5 minutes after the reboot' }
            Get-VMHost | Out-Null
            Write-Output 'HYPERV_OK'
    nextStep: CreateDcNetwork

  # The internal switch is the on-premises LAN. The host ROUTES it (no NAT), so
  # the hybrid node keeps its own IP end to end, which is what EKS expects from
  # a RemoteNodeNetwork. Internet egress is NATed further out, by the DC VPC.
  - name: CreateDcNetwork
    action: aws:runCommand
    timeoutSeconds: 300
    inputs:
      DocumentName: AWS-RunPowerShellScript
      InstanceIds: ['{{ InstanceId }}']
      Parameters:
        commands:
          - |
            if (-not (Get-VMSwitch -Name DCSwitch -ErrorAction SilentlyContinue)) {
              New-VMSwitch -Name DCSwitch -SwitchType Internal | Out-Null
            }
            if (-not (Get-NetIPAddress -IPAddress ${gateway_ip} -ErrorAction SilentlyContinue)) {
              New-NetIPAddress -IPAddress ${gateway_ip} -PrefixLength ${node_prefix} -InterfaceAlias 'vEthernet (DCSwitch)' | Out-Null
            }
            Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -Name IPEnableRouter -Value 1
            Set-Service -Name RemoteAccess -StartupType Automatic
            Start-Service RemoteAccess -ErrorAction SilentlyContinue
            Set-NetIPInterface -InterfaceAlias 'vEthernet (DCSwitch)' -Forwarding Enabled
            Get-NetAdapter -Physical | ForEach-Object { Set-NetIPInterface -InterfaceIndex $_.ifIndex -Forwarding Enabled }
            Get-NetNat -ErrorAction SilentlyContinue | Remove-NetNat -Confirm:$false -ErrorAction SilentlyContinue
            # Remote pod CIDR lives behind the VM (Cilium cluster-pool IPAM)
            route delete ${pod_net} 2>$null | Out-Null
            route -p add ${pod_net} mask ${pod_mask} ${vm_ip} metric 10 | Out-Null
            Write-Output 'DCNET_OK (routing mode, pod CIDR via the hybrid node VM)'

  - name: WaitImageBuild
    action: aws:waitForAwsResourceProperty
    timeoutSeconds: 2400
    inputs:
      Service: codebuild
      Api: BatchGetBuilds
      ids: ['{{ StartImageBuild.BuildId }}']
      PropertySelector: $.builds[0].buildStatus
      DesiredValues: [SUCCEEDED]

  - name: PrepareImage
    action: aws:runCommand
    timeoutSeconds: 1200
    inputs:
      DocumentName: AWS-RunPowerShellScript
      InstanceIds: ['{{ InstanceId }}']
      Parameters:
        commands:
          - |
            $ErrorActionPreference = 'Stop'
            $ProgressPreference = 'SilentlyContinue'
            New-Item -ItemType Directory -Path C:\lab -Force | Out-Null
            $target = 'C:\lab\ubuntu-base.vhdx'
            if (-not (Test-Path $target) -or (Get-Item $target).Length -lt 500MB) {
              Remove-Item $target -Force -ErrorAction SilentlyContinue
              Read-S3Object -BucketName ${bucket} -Key '${image_key}' -File $target | Out-Null
            }
            $len = (Get-Item $target).Length
            if ($len -lt 500MB) { throw "ubuntu-base.vhdx is only $len bytes - the S3 download was truncated" }
            Write-Output "IMAGE_OK ($len bytes)"

  - name: CreateVM
    action: aws:runCommand
    timeoutSeconds: 1200
    inputs:
      DocumentName: AWS-RunPowerShellScript
      InstanceIds: ['{{ InstanceId }}']
      Parameters:
        commands:
          - |
            $ErrorActionPreference = 'Stop'
            $ProgressPreference = 'SilentlyContinue'
            $vm = '${vm_name}'
            $ip = '${vm_ip}'
            $existing = @(Get-VM -Name $vm -ErrorAction SilentlyContinue)
            if ($existing.Count -eq 1 -and $existing[0].State -eq 'Running' -and (Test-Connection $ip -Count 2 -Quiet)) {
              Write-Output "$vm already running at $ip - preserving it"; exit 0
            }
            # A VM object alone is not idempotency: rebuild anything unhealthy
            $existing | Stop-VM -TurnOff -Force -ErrorAction SilentlyContinue
            $existing | Remove-VM -Force -ErrorAction SilentlyContinue
            $disk = "C:\lab\$vm.vhdx"
            $seed = "C:\lab\$vm-seed.vhdx"
            Remove-Item $disk, $seed -Force -ErrorAction SilentlyContinue
            Copy-Item C:\lab\ubuntu-base.vhdx $disk
            Resize-VHD -Path $disk -SizeBytes ${vm_disk_gb}GB
            # cloud-init NoCloud seed: a FAT32 volume labelled CIDATA (Windows has
            # no ISO tooling, and NoCloud accepts vfat)
            Read-S3Object -BucketName ${bucket} -Key '${user_data_key}' -File C:\lab\user-data | Out-Null
            Read-S3Object -BucketName ${bucket} -Key '${meta_data_key}' -File C:\lab\meta-data | Out-Null
            if ((Get-Item C:\lab\user-data).Length -lt 200) { throw 'user-data seed is empty - check the artifact bucket' }
            New-VHD -Path $seed -SizeBytes 64MB -Fixed | Out-Null
            $d = Mount-VHD -Path $seed -Passthru | Initialize-Disk -PartitionStyle MBR -PassThru
            $p = New-Partition -DiskNumber $d.Number -UseMaximumSize -AssignDriveLetter
            Format-Volume -DriveLetter $p.DriveLetter -FileSystem FAT32 -NewFileSystemLabel CIDATA | Out-Null
            Copy-Item C:\lab\user-data "$($p.DriveLetter):\user-data"
            Copy-Item C:\lab\meta-data "$($p.DriveLetter):\meta-data"
            Dismount-VHD -Path $seed
            Remove-Item C:\lab\user-data -Force
            # Gen2 + Secure Boot with the Microsoft UEFI CA template (boots Ubuntu)
            New-VM -Name $vm -MemoryStartupBytes ${vm_memory_gb}GB -Generation 2 -VHDPath $disk -SwitchName DCSwitch | Out-Null
            Set-VM -Name $vm -ProcessorCount ${vm_vcpus} -StaticMemory -CheckpointType Disabled -AutomaticStartAction Start -AutomaticStopAction ShutDown
            Set-VMFirmware -VMName $vm -EnableSecureBoot On -SecureBootTemplate MicrosoftUEFICertificateAuthority
            Add-VMHardDiskDrive -VMName $vm -Path $seed
            Start-VM -Name $vm
            $o = @(Get-VM -Name $vm)
            if ($o.Count -ne 1 -or $o[0].State -ne 'Running') { throw "$vm is not Running after Start-VM" }
            Write-Output "VM_STARTED ($vm, ${vm_vcpus} vCPU, ${vm_memory_gb} GB, $ip)"

  - name: HealthCheck
    action: aws:runCommand
    maxAttempts: 3
    timeoutSeconds: 900
    inputs:
      DocumentName: AWS-RunPowerShellScript
      InstanceIds: ['{{ InstanceId }}']
      Parameters:
        commands:
          - |
            $deadline = (Get-Date).AddMinutes(10)
            do {
              if (Test-Connection ${vm_ip} -Count 2 -Quiet) { Write-Output 'HEALTH_OK: the VM answers on the data center LAN'; exit 0 }
              Start-Sleep -Seconds 15
            } while ((Get-Date) -lt $deadline)
            throw 'VM ${vm_ip} not answering ICMP 10 minutes after boot (check cloud-init in the Hyper-V console)'

  # Outcome check: the VM registered with SSM through the Terraform activation,
  # which only happens inside nodeadm init. Ready in EKS follows within ~1 min.
  - name: WaitNodeRegistered
    action: aws:waitForAwsResourceProperty
    timeoutSeconds: 1800
    isEnd: true
    inputs:
      Service: ssm
      Api: DescribeInstanceInformation
      Filters:
        - Key: ActivationIds
          Values: ['${activation_id}']
      PropertySelector: $.InstanceInformationList[0].PingStatus
      DesiredValues: [Online]
