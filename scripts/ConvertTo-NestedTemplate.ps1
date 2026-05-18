<#
.SYNOPSIS
    把已裝好 ESXi 的 rtolab nested VM 轉成 vCenter template (frozen golden image).
    流程: Stop-VM -> 卸掉 CD-ROM ISO -> Set-VM -ToTemplate
    Template 命名: rtolab-tpl-vcf<v>-esx<NN>

.DESCRIPTION
    用情境: 部完 ESXi 又裝好 (ISO install 完成、guestinfo 套用 OK), 想把 VM 凍結
    起來當 golden, 之後要重來就 clone 不必再裝.

.PARAMETER Versions
    要轉的版本. 預設全部三版本.

.PARAMETER VMNamePattern
    額外指定 VM 名 pattern (例如某幾台). 不傳就轉版本內全部.

.EXAMPLE
    pwsh scripts\ConvertTo-NestedTemplate.ps1                  # 全 12 台轉
    pwsh scripts\ConvertTo-NestedTemplate.ps1 -Versions 9.0    # 只轉 9.0 那 4 台
#>

[CmdletBinding()]
param(
    [string[]] $Versions = @('9.0','9.1','5.2.1'),
    [string]   $VMNamePattern
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

$ErrorActionPreference = 'Continue'

foreach ($v in $Versions) {
    $vKey = $v -replace '\.',''
    Write-Host ""
    Write-Host "=== Version $v (vcf$vKey) ===" -ForegroundColor Cyan

    foreach ($h in $inv.hosts_by_version[$v]) {
        $vmName = $h.nested_vm_name
        if ($VMNamePattern -and $vmName -notlike $VMNamePattern) { continue }
        $tplName = "rtolab-tpl-vcf$vKey-$($h.name.Split('-')[-1])"   # e.g. rtolab-tpl-vcf90-esx01

        $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
        if (-not $vm) { Write-Warning "  VM $vmName 不存在, skip"; continue }
        if (Get-Template -Name $tplName -ErrorAction SilentlyContinue) {
            Write-Host "  [skip] $tplName template 已存在" -ForegroundColor DarkGray
            continue
        }

        # Power off
        if ($vm.PowerState -eq 'PoweredOn') {
            Write-Host "  [stop] $vmName..."
            try { Stop-VM -VM $vm -Kill -Confirm:$false -ErrorAction Stop | Out-Null } catch {}
            $deadline = (Get-Date).AddSeconds(60)
            while ((Get-Date) -lt $deadline -and (Get-VM -Id $vm.Id).PowerState -ne 'PoweredOff') {
                Start-Sleep 1
            }
        }

        # Unmount ISO (template 不應該掛 ISO)
        try {
            $cd = $vm | Get-CDDrive
            if ($cd.IsoPath) {
                Set-CDDrive -CD $cd -NoMedia -Confirm:$false | Out-Null
                Write-Host "  [cd]   unmounted ISO" -ForegroundColor DarkGray
            }
        } catch { Write-Warning "  $vmName CD unmount: $($_.Exception.Message)" }

        # Convert
        Write-Host "  [tpl]  $vmName -> $tplName" -ForegroundColor Green
        Set-VM -VM (Get-VM -Id $vm.Id) -ToTemplate -Confirm:$false -Name $tplName | Out-Null
    }
}

Disconnect-VIServer * -Confirm:$false -Force | Out-Null
Write-Host ""
Write-Host "完成. 列 template:  Get-Template -Name 'rtolab-tpl-*'" -ForegroundColor Cyan
