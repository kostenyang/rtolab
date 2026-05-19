<#
.SYNOPSIS
    部 VCF Installer (9.0 / 9.1) 或 Cloud Builder (5.2.1) appliance.

.DESCRIPTION
    從 inventory.artifacts 拿 OVA 路徑, 從 inventory.vcf.versions[v].management_domain.vcf_installer
    (9.x) 或 .cloud_builder (5.2.1) 拿 hostname/IP, 透過 OVF 屬性把 IP/DNS/root pw 設好,
    Import-VApp 到 Kosten RP + vsanDatastore (1) + selab-dswitch-pg114 (access VLAN 114,
    nested ESXi 那組 trunk portgroup 不能直接給 plain Linux VM 用), 然後 power on.

    9.0/9.1 用 vami.SDDC_Manager.* OVF properties, 5.2.1 用 guestinfo.* OVF properties.

.PARAMETER Versions
    要部哪幾版 (預設全部 9.0 9.1 5.2.1).

.PARAMETER WipeFirst
    先 wipe 同名 VM.

.EXAMPLE
    pwsh scripts/Deploy-VcfInstaller.ps1 -Versions 9.1
#>
[CmdletBinding()]
param(
    [string[]] $Versions = @('9.0','9.1','5.2.1'),
    [switch]   $WipeFirst
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $here '..')

Import-Module powershell-yaml
Import-Module VMware.VimAutomation.Core -ErrorAction Stop
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null

$inv     = Get-Content -Raw (Join-Path $repoRoot 'inventory/lab.yaml') | ConvertFrom-Yaml
$secrets = Get-Content -Raw (Join-Path $repoRoot 'inventory/secrets/lab.yaml') | ConvertFrom-Yaml

Connect-VIServer $inv.infra.outer_vcenter.fqdn `
    -User $inv.infra.outer_vcenter.user `
    -Password $secrets.outer_vcenter.sso_admin_pw -ErrorAction Stop | Out-Null

$rp = Get-ResourcePool -Name $inv.infra.deployment.resource_pool -ErrorAction Stop
$ds = Get-Datastore   -Name $inv.infra.deployment.datastore     -ErrorAction Stop
# Installer 用 access port (pg114), 不是 trunk
$pg = Get-VDPortgroup -Name 'selab-dswitch-pg114' -ErrorAction Stop
$cl = Get-Cluster     -Name $inv.infra.outer_vcenter.cluster   -ErrorAction Stop
$availableHosts = $cl | Get-VMHost | Where-Object { $_.ConnectionState -eq 'Connected' -and $_.PowerState -eq 'PoweredOn' }

# DNS / domain 共用
$dns      = $inv.infra.ad_dns.ip
$domain   = $inv.lab.domain
$ntp      = $inv.infra.ad_dns.ip
$netmask  = '255.255.255.0'
$gateway  = $inv.network.mgmt.gateway      # 192.168.114.254

foreach ($v in $Versions) {
    $vKey = $v -replace '\.',''
    Write-Host ""
    Write-Host "============ VCF $v installer ============" -ForegroundColor Cyan

    $vapp = Get-VApp -Name "rtolab-vcf$vKey" -ErrorAction SilentlyContinue
    if (-not $vapp) { Write-Warning "vApp rtolab-vcf$vKey 沒找到, 用 RP $($rp.Name) 為 parent (不放 vApp)"; }

    # ---- pick OVA + target FQDN/IP per-version --------------------------
    if ($v -in @('9.0','9.1')) {
        $ova    = $inv.artifacts."vcf_$vKey".vcf_installer_ova
        $tgt    = $inv.vcf.versions[$v].management_domain.vcf_installer
        $vmName = "vcf-installer-$vKey"
        $kind   = 'VCF Installer'
        $rootPw = $secrets.vcf_installer.root_pw
        $localPw = $secrets.vcf_installer.local_user_pw
    }
    elseif ($v -eq '5.2.1') {
        $ova    = $inv.artifacts.vcf_521.cloud_builder_ova
        $tgt    = $inv.vcf.versions[$v].management_domain.cloud_builder
        $vmName = "vcf-cloudbuilder-521"
        $kind   = 'Cloud Builder'
        $rootPw = $secrets.cloud_builder.root_pw
        $adminPw = $secrets.cloud_builder.admin_pw
    }
    else { Write-Warning "unknown version $v"; continue }

    if (-not $ova -or -not (Test-Path $ova)) { Write-Warning "OVA 不存在: $ova, skip $v"; continue }
    Write-Host "  OVA      : $ova"
    Write-Host "  Target   : $($tgt.fqdn) @ $($tgt.ip)"
    Write-Host "  VM name  : $vmName"

    # ---- wipe? ----------------------------------------------------------
    if ($WipeFirst -and (Get-VM -Name $vmName -ErrorAction SilentlyContinue)) {
        $existing = Get-VM -Name $vmName
        Write-Host "  [wipe] $vmName ..." -ForegroundColor Yellow
        if ($existing.PowerState -eq 'PoweredOn') { Stop-VM -VM $existing -Kill -Confirm:$false -ErrorAction SilentlyContinue | Out-Null; Start-Sleep 2 }
        Remove-VM -VM $existing -DeletePermanently -Confirm:$false | Out-Null
    }
    if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) {
        Write-Host "  [skip] $vmName 已存在 (沒下 -WipeFirst)" -ForegroundColor DarkGray
        continue
    }

    $vmhost = $availableHosts | Get-Random

    # ---- OVF config: 設 properties + network --------------------------------
    Write-Host "  loading OVF config ..."
    $cfg = Get-OvfConfiguration -Ovf $ova

    # network mapping
    if ($cfg.NetworkMapping) {
        $cfg.NetworkMapping.PSObject.Properties | ForEach-Object {
            $_.Value.Value = $pg
        }
    }

    if ($v -in @('9.0','9.1')) {
        # VCF Installer (SDDC_Manager 命名)
        $cfg.Common.ROOT_PASSWORD.Value        = $rootPw
        $cfg.Common.LOCAL_USER_PASSWORD.Value  = $localPw
        $cfg.Common.vami.hostname.Value        = $tgt.fqdn
        $cfg.Common.guestinfo.ntp.Value        = $ntp
        $cfg.vami.SDDC_Manager.ip0.Value       = $tgt.ip
        $cfg.vami.SDDC_Manager.netmask0.Value  = $netmask
        $cfg.vami.SDDC_Manager.gateway.Value   = $gateway
        $cfg.vami.SDDC_Manager.domain.Value    = $domain
        $cfg.vami.SDDC_Manager.searchpath.Value= $domain
        $cfg.vami.SDDC_Manager.DNS.Value       = $dns
        if ($cfg.vami.SDDC_Manager.PSObject.Properties['ip_address_version']) {
            $cfg.vami.SDDC_Manager.ip_address_version.Value = 'IPv4'
        }
    } else {
        # Cloud Builder 5.2.1
        $cfg.Common.guestinfo.ADMIN_USERNAME.Value = 'admin'
        $cfg.Common.guestinfo.ADMIN_PASSWORD.Value = $adminPw
        $cfg.Common.guestinfo.ROOT_PASSWORD.Value  = $rootPw
        $cfg.Common.guestinfo.hostname.Value       = $tgt.fqdn
        $cfg.Common.guestinfo.ip0.Value            = $tgt.ip
        $cfg.Common.guestinfo.netmask0.Value       = $netmask
        $cfg.Common.guestinfo.gateway.Value        = $gateway
        $cfg.Common.guestinfo.DNS.Value            = $dns
        $cfg.Common.guestinfo.domain.Value         = $domain
        $cfg.Common.guestinfo.searchpath.Value     = $domain
        $cfg.Common.guestinfo.ntp.Value            = $ntp
    }

    Write-Host "  Import-VApp (thin) into RP '$($rp.Name)' ..."
    $vm = Import-VApp -Source $ova -OvfConfiguration $cfg -Name $vmName `
                      -VMHost $vmhost -Datastore $ds -DiskStorageFormat Thin -Location $rp -Force -ErrorAction Stop

    if ($vapp) {
        Write-Host "  moving into vApp '$($vapp.Name)' ..."
        $vapp.ExtensionData.MoveIntoResourcePool(@($vm.ExtensionData.MoRef))
    }

    Write-Host "  powering on ($kind 第一次 boot 會跑 firstboot ~5-10 min) ..."
    (Get-VM -Id $vm.Id) | Start-VM -Confirm:$false | Out-Null
    Write-Host "  ✓ $vmName deployed @ $($tgt.ip)" -ForegroundColor Green
}

Disconnect-VIServer * -Confirm:$false -Force | Out-Null

Write-Host ""
Write-Host "完成. 等 ~5-10 min 給 appliance firstboot, 然後:"
Write-Host "  Test-Connection 192.168.114.{34,5,54}"
Write-Host "  https://kosten-vcf90-inst.rtolab.local   (9.0 VCF Installer)"
Write-Host "  https://kosten-vcf91-inst.rtolab.local   (9.1 VCF Installer)"
Write-Host "  https://kosten-vcf521-cb.rtolab.local    (5.2.1 Cloud Builder)" -ForegroundColor Cyan
