<#
.SYNOPSIS
    調整已部好的 nested ESXi VMs CPU/RAM, 按 inventory 的 vcf.versions[V].sizing.
    用法: deploy 完之後發現 sizing 不對, 跑這個一鍵 stop -> resize -> start.

.DESCRIPTION
    流程:
      1. 連 outer vC
      2. 每個指定 version: 找 rtolab-vcf<V> vApp
      3. Stop-VApp (graceful), 等所有 VM PoweredOff
      4. 對每台 VM: Set-VM -NumCpu/-MemoryGB 按 inventory
      5. Start-VApp

.PARAMETER Versions
    要調整的版本. 預設全部.

.EXAMPLE
    pwsh scripts\Resize-NestedESXi.ps1 -Versions 9.1     # 只調 9.1
#>

[CmdletBinding()]
param(
    [string[]] $Versions = @('9.0','9.1','5.2.1')
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

foreach ($v in $Versions) {
    $vKey = $v -replace '\.',''
    $vappName = "rtolab-vcf$vKey"
    $sz = $inv.vcf.versions[$v].sizing
    $vcpu = if ($sz -and $sz.vcpu)      { [int]$sz.vcpu }      else { 12 }
    $mem  = if ($sz -and $sz.memory_gb) { [int]$sz.memory_gb } else { 96 }

    Write-Host ""
    Write-Host "=== $v -> $vappName (target: $vcpu vCPU / $mem GB) ===" -ForegroundColor Cyan

    $vapp = Get-VApp -Name $vappName -ErrorAction SilentlyContinue
    if (-not $vapp) { Write-Warning "  vApp $vappName 不存在, skip"; continue }

    $vms = $vapp | Get-VM
    $needResize = $vms | Where-Object { $_.NumCpu -ne $vcpu -or $_.MemoryGB -ne $mem }
    if (-not $needResize) {
        Write-Host "  全部已是 $vcpu vCPU / $mem GB, skip" -ForegroundColor DarkGray
        continue
    }
    Write-Host "  $($needResize.Count) / $($vms.Count) VMs 需 resize"

    # 1. Stop vApp (powers off VMs gracefully via Tools, 然後 hard if stuck)
    Write-Host "  stopping vApp..."
    try { $vapp | Stop-VApp -Force -Confirm:$false | Out-Null } catch { Write-Warning "  stop vApp: $($_.Exception.Message)" }
    # 等 VMs PoweredOff
    $deadline = (Get-Date).AddMinutes(2)
    while ((Get-Date) -lt $deadline) {
        $onCount = ($vapp | Get-VM | Where-Object { $_.PowerState -eq 'PoweredOn' }).Count
        if ($onCount -eq 0) { break }
        Start-Sleep 2
    }

    # 2. Set-VM 每台
    foreach ($vm in $needResize) {
        $fresh = Get-VM -Id $vm.Id
        Write-Host "  [resize] $($fresh.Name): $($fresh.NumCpu) vCPU / $($fresh.MemoryGB) GB -> $vcpu / $mem"
        Set-VM -VM $fresh -NumCpu $vcpu -MemoryGB $mem -Confirm:$false | Out-Null
    }

    # 3. Start vApp
    Write-Host "  starting vApp..."
    $vapp | Start-VApp -Confirm:$false | Out-Null
    Write-Host "  ✓ $vappName done" -ForegroundColor Green
}

Disconnect-VIServer * -Confirm:$false -Force | Out-Null
Write-Host ""
Write-Host "完成. 驗證: Get-VM -Name 'vcf-m02-esx*' | ft Name, NumCpu, MemoryGB, PowerState" -ForegroundColor Cyan
