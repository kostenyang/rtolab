<#
.SYNOPSIS
    把已部好的 nested ESXi VMs 依版本分到 vApp 裡 (one-shot, retroactive).
    Deploy-NestedESXi.ps1 之後預設會直接 deploy 進 vApp, 這個 script 只給
    第一次部完 (還沒分組) 的情境用.

    建出來的 vApp:
      rtolab-vcf90  -> 4 台 (mgmt_ip 192.168.114.30-.33)
      rtolab-vcf91  -> 4 台 (mgmt_ip 192.168.114.14-.17)
      rtolab-vcf521 -> 4 台 (mgmt_ip 192.168.114.50-.53)
    vApp 開機順序: 同時 (parallel), 不依賴 (不像 web tier 要等 DB).

.EXAMPLE
    pwsh scripts\Group-NestedIntoVApps.ps1
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

$rp = Get-ResourcePool -Name $inv.infra.deployment.resource_pool -ErrorAction Stop

foreach ($v in $Versions) {
    $vKey = $v -replace '\.',''
    $vappName = "rtolab-vcf$vKey"
    $vmNames = $inv.hosts_by_version[$v] | ForEach-Object { $_.nested_vm_name }

    Write-Host ""
    Write-Host "=== $v -> vApp '$vappName' ===" -ForegroundColor Cyan

    # 找 / 建 vApp
    $vapp = Get-VApp -Name $vappName -ErrorAction SilentlyContinue
    if (-not $vapp) {
        Write-Host "  building vApp under RP '$($rp.Name)'..."
        $vapp = New-VApp -Name $vappName -Location $rp
    } else {
        Write-Host "  vApp 已存在"
    }

    # 把 VMs 搬進去
    foreach ($vmName in $vmNames) {
        $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
        if (-not $vm) {
            Write-Warning "  $vmName 不存在, skip"
            continue
        }
        $parent = $vm.ResourcePool.Name   # ResourcePool 屬性對 VM 而言代表「直接父 RP/vApp」
        if ($parent -eq $vappName) {
            Write-Host "  [skip] $vmName already in $vappName" -ForegroundColor DarkGray
            continue
        }
        Write-Host "  [move] $vmName ($parent -> $vappName)" -ForegroundColor Green
        Move-VM -VM $vm -Destination $vapp -Confirm:$false | Out-Null
    }
}

Write-Host ""
Write-Host "完成. 現在 RP '$($rp.Name)' 下會看到 3 個 vApp, 每個包 4 台 nested ESXi." -ForegroundColor Green
Disconnect-VIServer * -Confirm:$false -Force | Out-Null
