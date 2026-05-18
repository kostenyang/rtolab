<#
.SYNOPSIS
    把所有 rtolab nested ESXi VM 的 BootOrder 從「CD-ROM only」改成「Disk first」.
    解決 William Lam OVA 預設 boot order 只 CD-ROM, 沒 bootable ISO 就掉 BIOS 的問題.

.DESCRIPTION
    流程:
      1. 連 outer vC
      2. 對 vcf-m02-esx*-{90,91,521}: stop -> reconfig BootOptions.BootOrder
         = [Disk(Hard disk 1)] -> start
    Idempotent: 已經 Disk first 的 skip.

.EXAMPLE
    pwsh scripts\Fix-NestedBootOrder.ps1
#>

[CmdletBinding()]
param(
    [string] $VMNamePattern = 'vcf-m02-esx*'
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $here '..')

if (-not (Get-Module -ListAvailable powershell-yaml)) {
    Install-Module powershell-yaml -Scope CurrentUser -Force | Out-Null
}
Import-Module powershell-yaml
Import-Module VMware.VimAutomation.Core -ErrorAction Stop
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null

$inv     = Get-Content -Raw (Join-Path $repoRoot 'inventory/lab.yaml') | ConvertFrom-Yaml
$secrets = Get-Content -Raw (Join-Path $repoRoot 'inventory/secrets/lab.yaml') | ConvertFrom-Yaml

Connect-VIServer $inv.infra.outer_vcenter.fqdn `
    -User $inv.infra.outer_vcenter.user `
    -Password $secrets.outer_vcenter.sso_admin_pw -ErrorAction Stop | Out-Null

$vms = Get-VM -Name $VMNamePattern
Write-Host "Fixing BootOrder on $($vms.Count) VMs (Disk first, no CD-ROM)..." -ForegroundColor Cyan

$ErrorActionPreference = 'Continue'   # 一台失敗不停整個 loop
foreach ($vm in $vms) {
    $current = $vm.ExtensionData.Config.BootOptions.BootOrder
    $alreadyDisk = $current.Count -ge 1 -and $current[0].GetType().Name -eq 'VirtualMachineBootOptionsBootableDiskDevice'
    if ($alreadyDisk) {
        Write-Host "  [skip] $($vm.Name): already Disk first" -ForegroundColor DarkGray
        continue
    }

    # 找 Hard disk 1 的 device key
    $disk1 = $vm | Get-HardDisk | Where-Object { $_.Name -eq 'Hard disk 1' } | Select-Object -First 1
    if (-not $disk1) { Write-Warning "  $($vm.Name): 沒 Hard disk 1, skip"; continue }
    $diskKey = $disk1.ExtensionData.Key

    # Power off if on. 已關機就跳過 Stop (有些 VM 因 BIOS-無 boot 已自己降到 off-like 狀態 -> Stop-VM -Kill 會噴 "process not found")
    $fresh = Get-VM -Id $vm.Id
    $wasOn = $fresh.PowerState -eq 'PoweredOn'
    if ($wasOn) {
        Write-Host "  [stop] $($vm.Name)..."
        try {
            Stop-VM -VM $fresh -Kill -Confirm:$false -ErrorAction Stop | Out-Null
        } catch {
            Write-Host "    (stop noop: $($_.Exception.Message -split "`n" | Select-Object -First 1))" -ForegroundColor DarkGray
        }
        # 等 PoweredOff
        $deadline = (Get-Date).AddSeconds(60)
        while ((Get-Date) -lt $deadline -and (Get-VM -Id $vm.Id).PowerState -ne 'PoweredOff') {
            Start-Sleep 1
        }
    }

    Write-Host "  [reconfig] $($vm.Name): BootOrder = [Disk(key=$diskKey)]" -ForegroundColor Green
    $bootDisk = New-Object VMware.Vim.VirtualMachineBootOptionsBootableDiskDevice
    $bootDisk.DeviceKey = $diskKey
    $bootOpts = New-Object VMware.Vim.VirtualMachineBootOptions
    $bootOpts.BootOrder = @($bootDisk)
    $spec = New-Object VMware.Vim.VirtualMachineConfigSpec
    $spec.BootOptions = $bootOpts
    $task = $vm.ExtensionData.ReconfigVM_Task($spec)
    $taskView = Get-View $task
    while ($taskView.Info.State -in 'running','queued') {
        Start-Sleep 1
        $taskView.UpdateViewData('Info.State','Info.Error')
    }
    if ($taskView.Info.State -ne 'success') {
        Write-Warning "  $($vm.Name) reconfig failed: $($taskView.Info.Error.LocalizedMessage)"
        continue
    }

    if ($wasOn) {
        Write-Host "  [start] $($vm.Name)..."
        Start-VM -VM (Get-VM -Id $vm.Id) -Confirm:$false | Out-Null
    }
}

Write-Host ""
Write-Host "完成. nested ESXi 現在會從 Hard disk 1 boot." -ForegroundColor Green
Disconnect-VIServer * -Confirm:$false -Force | Out-Null
