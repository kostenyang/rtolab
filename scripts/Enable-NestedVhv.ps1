<#
.SYNOPSIS
    對 12 台 nested ESXi VM 打開 "Expose hardware-assisted virtualization to guest OS"
    (vhv.enable=TRUE), 讓 inner vCenter / vSAN ESA / NSX 等 64-bit guest 跑得起來.
    需要 VM PoweredOff. 會自動 stop → enable → start.
#>
[CmdletBinding()]
param(
    [string[]] $Names = @(
        'vcf-m02-esx01-521','vcf-m02-esx02-521','vcf-m02-esx03-521','vcf-m02-esx04-521',
        'vcf-m02-esx01-90', 'vcf-m02-esx02-90', 'vcf-m02-esx03-90', 'vcf-m02-esx04-90',
        'vcf-m02-esx01-91', 'vcf-m02-esx02-91', 'vcf-m02-esx03-91', 'vcf-m02-esx04-91'
    )
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

foreach ($n in $Names) {
    Write-Host ""
    Write-Host "=== $n ===" -ForegroundColor Cyan
    $vm = Get-VM -Name $n -ErrorAction SilentlyContinue
    if (-not $vm) { Write-Warning "  not found"; continue }

    # Check current vhv state
    $vhv = $vm.ExtensionData.Config.NestedHVEnabled
    if ($vhv -eq $true) {
        Write-Host "  vhv already enabled, skip" -ForegroundColor Green
        if ($vm.PowerState -ne 'PoweredOn') { Start-VM -VM $vm -Confirm:$false | Out-Null }
        continue
    }

    if ($vm.PowerState -eq 'PoweredOn') {
        Write-Host "  Stop-VM..."
        Stop-VM -VM $vm -Confirm:$false | Out-Null
        do { Start-Sleep 2 } while ((Get-VM -Id $vm.Id).PowerState -ne 'PoweredOff')
    }

    # Set NestedHVEnabled=true via VirtualMachineConfigSpec
    $cfg = New-Object VMware.Vim.VirtualMachineConfigSpec -Property @{ NestedHVEnabled = $true }
    $task = $vm.ExtensionData.ReconfigVM_Task($cfg)
    $tv = Get-View $task
    while ($tv.Info.State -in 'running','queued') { Start-Sleep 1; $tv.UpdateViewData('Info.State','Info.Error') }
    if ($tv.Info.State -eq 'success') {
        Write-Host "  ✓ vhv enabled" -ForegroundColor Green
    } else {
        Write-Warning "  reconfig: $($tv.Info.Error.LocalizedMessage)"
    }
    Start-VM -VM $vm -Confirm:$false | Out-Null
    Write-Host "  powered on"
}

Disconnect-VIServer * -Confirm:$false -Force | Out-Null
Write-Host ""
Write-Host "完成. 等 ~60sec 給 host boot, 然後再 retry bringup." -ForegroundColor Cyan
