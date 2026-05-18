<#
.SYNOPSIS
    從 rtolab-nested-esxi{8,9.0,9.1}.ova golden OVA 部署 esx02-04 (per version).
    用 OVF vApp properties (guestinfo.hostname / .ipaddress / .netmask / .gateway /
    .vlan / .dns / .domain / .ntp) 設值, master 內的 /etc/rc.local.d/local.sh 第一次
    開機讀 guestinfo 自動套.

.PARAMETER Versions
    要部哪幾個版本. 預設 全部三版本 (9.0, 9.1, 5.2.1).

.PARAMETER Hosts
    限定哪幾台 host (預設 esx02, esx03, esx04 — 因為 esx01 是 master).

.PARAMETER WipeFirst
    先 wipe 既有同名 VM (esx02-04 × 3 從之前用 William Lam OVA 部的, 已過時).
#>

[CmdletBinding()]
param(
    [string[]] $Versions = @('9.0','9.1','5.2.1'),
    [string[]] $Hosts    = @('esx02','esx03','esx04'),
    [switch]   $WipeFirst
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $here '..')

if (-not (Get-Module -ListAvailable powershell-yaml)) { Install-Module powershell-yaml -Scope CurrentUser -Force | Out-Null }
Import-Module powershell-yaml
Import-Module VMware.VimAutomation.Core -ErrorAction Stop
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null

$inv     = Get-Content -Raw (Join-Path $repoRoot 'inventory/lab.yaml') | ConvertFrom-Yaml
$secrets = Get-Content -Raw (Join-Path $repoRoot 'inventory/secrets/lab.yaml') | ConvertFrom-Yaml

Connect-VIServer $inv.infra.outer_vcenter.fqdn `
    -User $inv.infra.outer_vcenter.user `
    -Password $secrets.outer_vcenter.sso_admin_pw -ErrorAction Stop | Out-Null

$rp = Get-ResourcePool -Name $inv.infra.deployment.resource_pool -ErrorAction Stop
$ds = Get-Datastore   -Name $inv.infra.deployment.datastore -ErrorAction Stop
$pg = Get-VDPortgroup -Name $inv.infra.deployment.portgroup -ErrorAction Stop
$cl = Get-Cluster     -Name $inv.infra.outer_vcenter.cluster -ErrorAction Stop
$availableHosts = $cl | Get-VMHost | Where-Object { $_.ConnectionState -eq 'Connected' -and $_.PowerState -eq 'PoweredOn' }
$ovaMap = @{
    '5.2.1' = 'E:\custom-ova\rtolab-nested-esxi8.ova'
    '9.0'   = 'E:\custom-ova\rtolab-nested-esxi9.0.ova'
    '9.1'   = 'E:\custom-ova\rtolab-nested-esxi9.1.ova'
}

foreach ($v in $Versions) {
    $vKey  = $v -replace '\.',''
    $ova   = $ovaMap[$v]
    if (-not (Test-Path $ova)) { Write-Warning "skip $v : golden OVA 不存在 $ova"; continue }
    $vappName = "rtolab-vcf$vKey"
    $deployVapp = Get-VApp -Name $vappName -ErrorAction Stop

    foreach ($h in $inv.hosts_by_version[$v]) {
        $shortName = $h.name.Split('-')[-1]   # esx01..esx04
        if ($Hosts -notcontains $shortName) { continue }

        $vmName = $h.nested_vm_name
        Write-Host ""
        Write-Host "=== $v / $vmName -> $($h.mgmt_ip) ===" -ForegroundColor Cyan

        if ($WipeFirst -and (Get-VM -Name $vmName -ErrorAction SilentlyContinue)) {
            Write-Host "  [wipe] $vmName ..." -ForegroundColor Yellow
            $existing = Get-VM -Name $vmName
            if ($existing.PowerState -eq 'PoweredOn') { Stop-VM -VM $existing -Kill -Confirm:$false -ErrorAction SilentlyContinue | Out-Null }
            Start-Sleep 2
            Remove-VM -VM $existing -DeletePermanently -Confirm:$false | Out-Null
        }
        if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) {
            Write-Host "  [skip] $vmName 已存在 (沒下 -WipeFirst)" -ForegroundColor DarkGray
            continue
        }

        $vmhost = $availableHosts | Get-Random

        # 從 golden OVA 拿 OVF config + 設 guestinfo
        Write-Host "  loading OVF config from $ova ..."
        $ovfconfig = Get-OvfConfiguration -Ovf $ova
        if ($ovfconfig.Common) {
            # 我們 Export-NestedEsxiOva 注入的 properties: guestinfo.hostname / .ipaddress / .netmask / .gateway / .vlan / .dns / .domain / .ntp / .password
            $tryset = @{
                hostname  = $h.fqdn
                ipaddress = $h.mgmt_ip
                netmask   = '255.255.255.0'
                gateway   = $inv.network.mgmt.gateway
                vlan      = [string]$inv.network.mgmt.vlan
                dns       = $inv.infra.ad_dns.ip
                domain    = $inv.lab.domain
                ntp       = $inv.infra.ad_dns.ip
                password  = $secrets.esxi.root_pw
            }
            foreach ($k in $tryset.Keys) {
                $propName = "guestinfo.$k"
                $prop = $ovfconfig.Common.PSObject.Properties[$propName]
                if (-not $prop) {
                    # 可能 OVF property 是 nested 在 .Common.guestinfo. 物件 (見 Build-EsxiKickstartIso pattern)
                    if ($ovfconfig.Common.guestinfo) {
                        $sub = $ovfconfig.Common.guestinfo.PSObject.Properties[$k]
                        if ($sub) { $sub.Value.Value = $tryset[$k]; continue }
                    }
                    Write-Warning "  OVF missing property: $propName"
                } else {
                    $prop.Value.Value = $tryset[$k]
                }
            }
        }
        if ($ovfconfig.NetworkMapping) {
            foreach ($nm in $ovfconfig.NetworkMapping.PSObject.Properties) {
                $nm.Value.Value = $pg
            }
        }

        Write-Host "  Import-VApp (thin) into RP '$($rp.Name)' ..."
        $vm = Import-VApp -Source $ova -OvfConfiguration $ovfconfig -Name $vmName `
                          -VMHost $vmhost -Datastore $ds -DiskStorageFormat Thin -Location $rp -Force -ErrorAction Stop

        # 直接寫 ExtraConfig guestinfo.* (我的 hand-built OVA OvfEnvironmentTransport 空,
        # 所以 vAppConfig.Property 沒注入成 guestinfo; ExtraConfig 是最直接的 channel,
        # vmware-rpctool 'info-get guestinfo.X' 會直接讀)
        Write-Host "  setting ExtraConfig guestinfo.* (bypass OVF transport) ..."
        $extras = @(
            @{ Key='guestinfo.hostname';  Value=$h.fqdn },
            @{ Key='guestinfo.ipaddress'; Value=$h.mgmt_ip },
            @{ Key='guestinfo.netmask';   Value='255.255.255.0' },
            @{ Key='guestinfo.gateway';   Value=$inv.network.mgmt.gateway },
            @{ Key='guestinfo.vlan';      Value=[string]$inv.network.mgmt.vlan },
            @{ Key='guestinfo.dns';       Value=$inv.infra.ad_dns.ip },
            @{ Key='guestinfo.domain';    Value=$inv.lab.domain },
            @{ Key='guestinfo.ntp';       Value=$inv.infra.ad_dns.ip }
        )
        $cfg = New-Object VMware.Vim.VirtualMachineConfigSpec -Property @{
            ExtraConfig = $extras | ForEach-Object { New-Object VMware.Vim.OptionValue -Property $_ }
        }
        $task = $vm.ExtensionData.ReconfigVM_Task($cfg)
        $tv = Get-View $task
        while ($tv.Info.State -in 'running','queued') { Start-Sleep 1; $tv.UpdateViewData('Info.State','Info.Error') }
        if ($tv.Info.State -ne 'success') { Write-Warning "  ExtraConfig reconfig: $($tv.Info.Error.LocalizedMessage)" }

        Write-Host "  moving into vApp '$vappName' ..."
        $deployVapp.ExtensionData.MoveIntoResourcePool(@($vm.ExtensionData.MoRef))

        Write-Host "  powering on (local.sh 第一次跑 -> 自動套 IP/hostname) ..."
        (Get-VM -Id $vm.Id) | Start-VM -Confirm:$false | Out-Null
        Write-Host "  ✓ $vmName done" -ForegroundColor Green
    }
}

Disconnect-VIServer * -Confirm:$false -Force | Out-Null
Write-Host ""
Write-Host "完成. 等 ~2-3 min 給 local.sh 套設定, 然後 Test-Connection 看 IP 通了沒." -ForegroundColor Cyan
