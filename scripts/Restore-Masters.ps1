<#
.SYNOPSIS
    把 3 個 master template (esx01-{521,90,91}-master) 轉回 VM, 移進對應 vApp,
    開機 + 套上正確 IP/gateway (.254) — 因為 DCUI 手裝時 gateway 設成 .1 是錯的.

.NOTES
    template 名 = "<vmname>-master" (ConvertTo-NestedTemplate 把 -91/-90/-521 重命名為 -master).
    這裡轉回時改名拿掉 -master 後綴, 對應 inventory 的 nested_vm_name.
#>
[CmdletBinding()]
param(
    [string[]] $Versions = @('9.0','9.1','5.2.1')
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $here '..')

Import-Module powershell-yaml
Import-Module VMware.VimAutomation.Core
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null

$inv     = Get-Content -Raw (Join-Path $repoRoot 'inventory/lab.yaml') | ConvertFrom-Yaml
$secrets = Get-Content -Raw (Join-Path $repoRoot 'inventory/secrets/lab.yaml') | ConvertFrom-Yaml

Connect-VIServer $inv.infra.outer_vcenter.fqdn `
    -User $inv.infra.outer_vcenter.user `
    -Password $secrets.outer_vcenter.sso_admin_pw | Out-Null

foreach ($v in $Versions) {
    $vKey = $v -replace '\.',''
    $vappName = "rtolab-vcf$vKey"
    $vapp = Get-VApp -Name $vappName -ErrorAction SilentlyContinue
    if (-not $vapp) { Write-Warning "vApp $vappName not found, skip"; continue }

    $masterHost = $inv.hosts_by_version[$v] | Where-Object { $_.name -like '*esx01' } | Select-Object -First 1
    if (-not $masterHost) { Write-Warning "no esx01 entry for $v"; continue }
    $vmName = $masterHost.nested_vm_name
    $tplName = "$vmName-master"

    $tpl = Get-Template -Name $tplName -ErrorAction SilentlyContinue
    if (-not $tpl) {
        # maybe already converted back?
        $existing = Get-VM -Name $vmName -ErrorAction SilentlyContinue
        if ($existing) { Write-Host "[$v] $vmName already VM, will reconfigure" -ForegroundColor DarkGray }
        else { Write-Warning "[$v] template $tplName not found and no VM either"; continue }
    } else {
        Write-Host ""
        Write-Host "=== [$v] $tplName -> VM $vmName ===" -ForegroundColor Cyan
        Set-Template -Template $tpl -ToVM -Confirm:$false | Out-Null
        # rename (-master suffix off)
        $convertedVm = Get-VM -Name $tplName -ErrorAction SilentlyContinue
        if ($convertedVm) {
            Set-VM -VM $convertedVm -Name $vmName -Confirm:$false | Out-Null
            # move into vApp
            $vapp.ExtensionData.MoveIntoResourcePool(@($convertedVm.ExtensionData.MoRef))
        }
    }

    $vm = Get-VM -Name $vmName -ErrorAction Stop
    if ($vm.PowerState -ne 'PoweredOn') {
        Write-Host "  powering on $vmName ..." -ForegroundColor Yellow
        Start-VM -VM $vm -Confirm:$false | Out-Null
    }
}

Disconnect-VIServer * -Confirm:$false -Force | Out-Null
Write-Host ""
Write-Host "完成. 等 ~60 sec 讓 ESXi boot + VMware Tools 起來, 然後跑 Apply-CloneIp.ps1 -Hosts esx01" -ForegroundColor Cyan
