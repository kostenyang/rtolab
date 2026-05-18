<#
.SYNOPSIS
    把 rtolab.local zone 的 A 記錄 push 到 AD/DNS (kosten.rtolab.local @ 192.168.114.200).
    一次寫一個版本的 mgmt VMs + 4 台 ESXi + shared (kosten / jumpbox / installer 三件).

.DESCRIPTION
    從 inventory/lab.yaml 讀:
      - vcf.versions[Version].management_domain      (sddc / vCenter / NSX / vcf_installer / operations)
      - hosts_by_version[Version]                    (esx01-04 + 對應 IP)
      - 共用: kosten, selab-win2022-jump, selabvc, 另外兩版的 installer/CB FQDN (常駐)
    建 zone (如果不存在) -> 對每筆 A record:
      - 如果不存在: 加
      - 如果已存在且 IP 不對: 蓋掉
      - 已對: 略過

.PARAMETER Version
    要 push 的 active version (9.0 / 9.1 / 5.2.1). 預設讀 inventory 的 vcf.version.

.PARAMETER Local
    在 kosten (AD/DNS) 本機直接跑時加這個 — 不走 WinRM, 直接呼叫 DnsServer module 的 local cmdlets.

.PARAMETER DnsServer
    Remote 模式下的 DNS server (預設 192.168.114.200 = kosten).

.PARAMETER ZoneName
    DNS zone (預設 rtolab.local).

.PARAMETER WhatIf
    只列要做什麼, 不真的改 DNS.

.EXAMPLE
    # Remote (從 Windows jumpbox 推, 需 kosten 開 WinRM)
    pwsh scripts\Set-DnsRecords.ps1 -Version 9.0

.EXAMPLE
    # Local (RDP 上 kosten, copy 這份腳本 + inventory/lab.yaml 過去, 直接跑)
    pwsh Set-DnsRecords.ps1 -Version 9.0 -Local
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [ValidateSet('9.0','9.1','5.2.1','')] [string] $Version = '',
    [switch] $Local,
    [string] $DnsServer = '192.168.114.200',
    [string] $ZoneName  = 'rtolab.local',
    [PSCredential] $Credential
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $here '..')

# 載入 powershell-yaml
if (-not (Get-Module -ListAvailable powershell-yaml)) {
    Install-Module powershell-yaml -Scope CurrentUser -Force | Out-Null
}
Import-Module powershell-yaml
Import-Module DnsServer -ErrorAction Stop

$inv = Get-Content -Raw (Join-Path $repoRoot 'inventory/lab.yaml') | ConvertFrom-Yaml

if (-not $Version) { $Version = if ($inv.vcf.version) { [string]$inv.vcf.version } else { '9.0' } }
if ($Version -notin @('9.0','9.1','5.2.1')) { throw "Version 必須是 9.0 / 9.1 / 5.2.1" }
Write-Host "DNS push for VCF $Version -> zone $ZoneName on $DnsServer" -ForegroundColor Cyan

# ---- 蒐集 A records ------------------------------------------------------
$records = [System.Collections.Generic.List[object]]::new()

function Add-Rec {
    param([string]$Name, [string]$Ip, [string]$Comment = '')
    if (-not $Name -or -not $Ip -or $Ip -eq 'REPLACE_ME') {
        Write-Warning "skip $Name (no IP)"
        return
    }
    # FQDN -> 拿 hostname (zone 內的相對名)
    $rel = if ($Name -like "*.$ZoneName") { $Name.Substring(0, $Name.Length - $ZoneName.Length - 1) } else { $Name }
    $records.Add([pscustomobject]@{ Name = $rel; Ip = $Ip; Comment = $Comment })
}

# 共用 (三版本都需要)
Add-Rec $inv.infra.ad_dns.fqdn          $inv.infra.ad_dns.ip          'AD/DNS (self)'
Add-Rec $inv.infra.automation_host.fqdn $inv.infra.automation_host.ip 'Windows jumpbox (跨 subnet)'
Add-Rec $inv.infra.outer_vcenter.fqdn   $inv.infra.outer_vcenter.ip   'SELAB-Cluster outer vC'

# Active version 的 mgmt VMs + 4 台 ESXi
$vb = $inv.vcf.versions[$Version]
$md = $vb.management_domain
Add-Rec $md.sddc_manager.fqdn  $md.sddc_manager.ip  "[$Version] SDDC Manager"
Add-Rec $md.inner_vcenter.fqdn $md.inner_vcenter.ip "[$Version] inner vCenter"
Add-Rec $md.nsx_manager.fqdn   $md.nsx_manager.vip  "[$Version] NSX VIP"
if ($md.nsx_manager.node_fqdn) { Add-Rec $md.nsx_manager.node_fqdn $md.nsx_manager.node_ip "[$Version] NSX node 1" }
if ($md.vcf_installer) { Add-Rec $md.vcf_installer.fqdn $md.vcf_installer.ip "[$Version] VCF Installer" }
if ($md.cloud_builder) { Add-Rec $md.cloud_builder.fqdn $md.cloud_builder.ip "[$Version] Cloud Builder" }
if ($md.operations) {
    Add-Rec $md.operations.fqdn           $md.operations.ip            "[$Version] VCF Operations"
    Add-Rec $md.operations.fleet_fqdn     $md.operations.fleet_ip      "[$Version] Fleet Mgmt"
    Add-Rec $md.operations.collector_fqdn $md.operations.collector_ip  "[$Version] Collector"
    # 注意: operations IP 在 inventory 沒明列, 用 ip-plan.md 的 .40/.41/.42 (9.0 only)
    if (-not $md.operations.ip) {
        Add-Rec $md.operations.fqdn           '192.168.114.40' "[$Version] VCF Operations (from ip-plan)"
        Add-Rec $md.operations.fleet_fqdn     '192.168.114.41' "[$Version] Fleet Mgmt (from ip-plan)"
        Add-Rec $md.operations.collector_fqdn '192.168.114.42' "[$Version] Collector (from ip-plan)"
    }
}

foreach ($h in $inv.hosts_by_version[$Version]) {
    Add-Rec $h.fqdn $h.mgmt_ip "[$Version] $($h.name)"
}

# 也把另外兩版的 installer/CB FQDN 加進去 (常駐 appliance, 可同時存在)
foreach ($otherV in @('9.0','9.1','5.2.1') | Where-Object { $_ -ne $Version }) {
    $ob = $inv.vcf.versions[$otherV]
    if ($ob.management_domain.vcf_installer) {
        Add-Rec $ob.management_domain.vcf_installer.fqdn `
                $ob.management_domain.vcf_installer.ip   "[$otherV] VCF Installer (常駐)"
    }
    if ($ob.management_domain.cloud_builder) {
        Add-Rec $ob.management_domain.cloud_builder.fqdn `
                $ob.management_domain.cloud_builder.ip   "[$otherV] Cloud Builder (常駐)"
    }
}

Write-Host ""
Write-Host "要寫的 A 記錄 ($($records.Count)):" -ForegroundColor Yellow
$records | Format-Table Name, Ip, Comment -AutoSize

# ---- 套用 -----------------------------------------------------------------
# 建 CIM session (remote 模式)
$cimSess = $null
if (-not $Local) {
    if (-not $Credential) {
        $Credential = Get-Credential -Message "rtolab AD admin for DNS push (e.g. rtolab\administrator)"
    }
    $opt = New-CimSessionOption -Protocol Wsman
    $cimSess = New-CimSession -ComputerName $DnsServer -Credential $Credential -SessionOption $opt -Authentication Negotiate
}

# Zone exists?
$zoneArgs = @{}
if ($cimSess) { $zoneArgs.CimSession = $cimSess }
$zone = $null
try { $zone = Get-DnsServerZone -Name $ZoneName @zoneArgs -ErrorAction Stop } catch {}
if (-not $zone) {
    Write-Host "Zone $ZoneName 不存在, 建立 (Primary, dynamic update: secure)..." -ForegroundColor Yellow
    if ($PSCmdlet.ShouldProcess($ZoneName, 'Add-DnsServerPrimaryZone')) {
        Add-DnsServerPrimaryZone -Name $ZoneName -ReplicationScope Domain -DynamicUpdate Secure @zoneArgs
    }
}

foreach ($r in $records) {
    $existing = $null
    try {
        $existing = Get-DnsServerResourceRecord -ZoneName $ZoneName -Name $r.Name -RRType A @zoneArgs -ErrorAction Stop
    } catch {}

    if ($existing) {
        $curIp = $existing.RecordData.IPv4Address.IPAddressToString
        if ($curIp -eq $r.Ip) {
            Write-Host "  [skip] $($r.Name) -> $($r.Ip)" -ForegroundColor DarkGray
            continue
        }
        Write-Host "  [update] $($r.Name): $curIp -> $($r.Ip)" -ForegroundColor Yellow
        if ($PSCmdlet.ShouldProcess("$($r.Name).$ZoneName -> $($r.Ip)", 'Remove+Add A record')) {
            Remove-DnsServerResourceRecord -ZoneName $ZoneName -InputObject $existing -Force @zoneArgs
            Add-DnsServerResourceRecordA -ZoneName $ZoneName -Name $r.Name -IPv4Address $r.Ip @zoneArgs
        }
    } else {
        Write-Host "  [add]  $($r.Name) -> $($r.Ip)" -ForegroundColor Green
        if ($PSCmdlet.ShouldProcess("$($r.Name).$ZoneName -> $($r.Ip)", 'Add A record')) {
            Add-DnsServerResourceRecordA -ZoneName $ZoneName -Name $r.Name -IPv4Address $r.Ip @zoneArgs
        }
    }
}

if ($cimSess) { Remove-CimSession $cimSess }
Write-Host ""
Write-Host "完成. 驗證:  Resolve-DnsName -Server $DnsServer sddc-mgr.$ZoneName" -ForegroundColor Cyan
