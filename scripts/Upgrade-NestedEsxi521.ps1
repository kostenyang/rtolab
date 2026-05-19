<#
.SYNOPSIS
    把 4 台 5.2.1 nested ESXi (.50-.53) 從 8.0U3 GA build 24022510 升到 8.0U3b
    build 24280767 (CB 5.2.1 GA 要求).

.DESCRIPTION
    1. 確認 datastore 上有 esxi-8.0U3b-24280767.iso (本 script 之前 upload 好的)
    2. 對每台 VM: stop, mount ISO 到 CDROM, 改 boot order CDROM first, power on
    3. **用戶要從 vCenter Web Console 進 ESXi 安裝程式選 "Upgrade" 保留 VMFS**
       (esxcli software profile update -d <iso> 不收 ISO, 沒拿到 offline depot zip,
        只能走 boot-from-installer)
    4. 升完後手動取消 CDROM Connect at PowerOn, 改回 disk boot

    Alternative: 升完一台 master, /sbin/auto-backup.sh, Export-NestedEsxiOva, redeploy clones.
#>

[CmdletBinding()]
param(
    [string[]] $Hosts = @('vcf-m02-esx01-521','vcf-m02-esx02-521','vcf-m02-esx03-521','vcf-m02-esx04-521'),
    [string]   $IsoDatastorePath = '[vsanDatastore (1)] iso/esxi-8.0U3b-24280767.iso'
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $here '..')

Import-Module powershell-yaml
Import-Module VMware.VimAutomation.Core
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null
$inv = Get-Content -Raw (Join-Path $repoRoot 'inventory/lab.yaml') | ConvertFrom-Yaml
$secrets = Get-Content -Raw (Join-Path $repoRoot 'inventory/secrets/lab.yaml') | ConvertFrom-Yaml
Connect-VIServer $inv.infra.outer_vcenter.fqdn -User $inv.infra.outer_vcenter.user -Password $secrets.outer_vcenter.sso_admin_pw | Out-Null

foreach ($vmName in $Hosts) {
    Write-Host ""
    Write-Host "=== $vmName ===" -ForegroundColor Cyan
    $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if (-not $vm) { Write-Warning "  not found"; continue }

    if ($vm.PowerState -eq 'PoweredOn') {
        Write-Host "  Stop-VM..."
        Stop-VM -VM $vm -Confirm:$false | Out-Null
        do { Start-Sleep 2 } while ((Get-VM -Id $vm.Id).PowerState -ne 'PoweredOff')
    }

    # Mount ISO
    Write-Host "  Mounting ISO: $IsoDatastorePath"
    Get-CDDrive -VM $vm | Set-CDDrive -IsoPath $IsoDatastorePath -StartConnected:$true -Confirm:$false | Out-Null

    # Set boot order: CDROM first then disk
    $bootOpts = New-Object VMware.Vim.VirtualMachineBootOptions
    $bootOpts.BootOrder = @(
        (New-Object VMware.Vim.VirtualMachineBootOptionsBootableCdromDevice),
        (New-Object VMware.Vim.VirtualMachineBootOptionsBootableDiskDevice -Property @{ DeviceKey = ($vm.ExtensionData.Config.Hardware.Device | Where-Object { $_.GetType().Name -eq 'VirtualDisk' } | Select-Object -First 1 -ExpandProperty Key) })
    )
    $cfg = New-Object VMware.Vim.VirtualMachineConfigSpec -Property @{ BootOptions = $bootOpts }
    $task = $vm.ExtensionData.ReconfigVM_Task($cfg)
    Get-View -Id $task | Out-Null

    Write-Host "  Powering on (boot from ISO)..."
    Start-VM -VM $vm -Confirm:$false | Out-Null

    Write-Host "  >>> 從 vCenter UI 開 $vmName 的 Web Console, 看到 ESXi installer welcome 後:"
    Write-Host "      F11 EULA → 選 'Upgrade ESXi, preserve VMFS datastore' → Enter → F11 confirm → wait ~5min → reboot"
    Write-Host "      (升完會自動 reboot, build → 24280767)"
}

Disconnect-VIServer * -Confirm:$false -Force | Out-Null

Write-Host ""
Write-Host "下一步:"
Write-Host "  從 vCenter UI 每台 console 互動完成 Upgrade"
Write-Host "  全部好了再跑 layer2-bringup/vcf521/New-VcfLab.ps1 -CloudBuilder https://192.168.114.54"
