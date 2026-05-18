<#
.SYNOPSIS
    Push rtolab.local zone 三組 VCF FQDN (9.0 / 9.1 / 5.2.1) + 反向 PTR
    + 底層 vmotion/vsan vmk FQDN 到 AD/DNS (kosten.rtolab.local @ 192.168.114.200).
    預設一次推完三版本; -Version 可限定單一版本.

.DESCRIPTION
    從 inventory/lab.yaml 讀:
      - vcf.versions[V].management_domain (sddc/vc/nsx/inst/cb/ops/fleet/coll)
      - hosts_by_version[V] (esx01-04 mgmt/vmotion/vsan FQDN+IP)
      - 共用: kosten / selab-win2022-jump / selabvc

    建 forward zone rtolab.local + 三條反向 zone:
      114.168.192.in-addr.arpa (mgmt)
      115.168.192.in-addr.arpa (vmotion)
      116.168.192.in-addr.arpa (vsan)
      10.16.172.in-addr.arpa  (Windows jumpbox 段)

    Idempotent: 已對的 skip, 漂移的 update, 新的 add.
    -CleanupLegacy 會把舊的 short FQDN (sddc-mgr / esx01 / vcf-* / nsx-mgmt 等)
                  A 記錄連同 PTR 一起刪掉.

.PARAMETER Version
    限定推某個版本 (9.0 / 9.1 / 5.2.1). 不指定就推全部三版本.

.PARAMETER Local
    在 kosten 本機跑時用; 不走 WinRM.

.PARAMETER CleanupLegacy
    刪除舊的 short FQDN (rtolab.local zone 上的 sddc-mgr, vc-mgmt, nsx-mgmt,
    nsx-mgmt-01, vcf-inst-90, vcf-inst-91, vcf-cb, vcf-ops, vcf-fleet,
    vcf-coll, esx01-04) 連同它們的 PTR.

.PARAMETER DnsServer
    Remote 模式下的 DNS server (預設 192.168.114.200).

.PARAMETER ZoneName
    Forward zone (預設 rtolab.local).

.EXAMPLE
    pwsh scripts\Set-DnsRecords.ps1 -CleanupLegacy
    # 一次推三版本 FQDN, 順便清掉舊的 short FQDN
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [ValidateSet('9.0','9.1','5.2.1','')] [string] $Version = '',
    [switch] $Local,
    [switch] $CleanupLegacy,
    [string] $DnsServer = '192.168.114.200',
    [string] $ZoneName  = 'rtolab.local',
    [PSCredential] $Credential
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $here '..')

if (-not (Get-Module -ListAvailable powershell-yaml)) {
    Install-Module powershell-yaml -Scope CurrentUser -Force | Out-Null
}
Import-Module powershell-yaml
Import-Module DnsServer -ErrorAction Stop

$inv = Get-Content -Raw (Join-Path $repoRoot 'inventory/lab.yaml') | ConvertFrom-Yaml

# 哪些版本要推
$targetVersions = if ($Version) { @($Version) } else { @('9.0','9.1','5.2.1') }
Write-Host "DNS push for VCF versions: $($targetVersions -join ', ') -> zone $ZoneName on $DnsServer" -ForegroundColor Cyan

# ---- 蒐集所有 A 記錄 -----------------------------------------------------
$records = [System.Collections.Generic.List[object]]::new()

function Add-Rec {
    param([string]$Name, [string]$Ip, [string]$Comment = '')
    if (-not $Name -or -not $Ip -or $Ip -eq 'REPLACE_ME') {
        Write-Warning "skip $Name (no IP)"
        return
    }
    $rel = if ($Name -like "*.$ZoneName") { $Name.Substring(0, $Name.Length - $ZoneName.Length - 1) } else { $Name }
    $records.Add([pscustomobject]@{ Name = $rel; Ip = $Ip; Comment = $Comment })
}

# Shared (三版本都共用) — kosten/jumpbox/selabvc 各一筆
Add-Rec $inv.infra.ad_dns.fqdn          $inv.infra.ad_dns.ip          'AD/DNS (kosten)'
Add-Rec $inv.infra.automation_host.fqdn $inv.infra.automation_host.ip 'Windows jumpbox (跨 subnet)'
Add-Rec $inv.infra.outer_vcenter.fqdn   $inv.infra.outer_vcenter.ip   'SELAB-Cluster outer vC'

# 每個目標版本: management VMs + 4 ESXi (mgmt/vmotion/vsan vmk)
foreach ($v in $targetVersions) {
    $vb = $inv.vcf.versions[$v]
    if (-not $vb) { Write-Warning "inventory 沒有版本 $v"; continue }
    $md = $vb.management_domain
    Add-Rec $md.sddc_manager.fqdn        $md.sddc_manager.ip   "[$v] SDDC Manager"
    Add-Rec $md.inner_vcenter.fqdn       $md.inner_vcenter.ip  "[$v] inner vCenter"
    Add-Rec $md.nsx_manager.fqdn         $md.nsx_manager.vip   "[$v] NSX VIP"
    if ($md.nsx_manager.node_fqdn) { Add-Rec $md.nsx_manager.node_fqdn $md.nsx_manager.node_ip "[$v] NSX node 1" }
    if ($md.vcf_installer)         { Add-Rec $md.vcf_installer.fqdn    $md.vcf_installer.ip    "[$v] VCF Installer" }
    if ($md.cloud_builder)         { Add-Rec $md.cloud_builder.fqdn    $md.cloud_builder.ip    "[$v] Cloud Builder" }
    if ($md.operations) {
        Add-Rec $md.operations.fqdn           ($md.operations.fqdn_ip      ?? '192.168.114.40') "[$v] VCF Operations"
        Add-Rec $md.operations.fleet_fqdn     ($md.operations.fleet_ip     ?? '192.168.114.41') "[$v] Fleet Mgmt"
        Add-Rec $md.operations.collector_fqdn ($md.operations.collector_ip ?? '192.168.114.42') "[$v] Collector"
    }
    foreach ($h in $inv.hosts_by_version[$v]) {
        Add-Rec $h.fqdn         $h.mgmt_ip    "[$v] $($h.name) mgmt vmk"
        Add-Rec $h.vmotion_fqdn $h.vmotion_ip "[$v] $($h.name) vmotion vmk"
        Add-Rec $h.vsan_fqdn    $h.vsan_ip    "[$v] $($h.name) vsan vmk"
    }
}

Write-Host ""
Write-Host "要寫的 A 記錄 ($($records.Count)):" -ForegroundColor Yellow
$records | Format-Table Name, Ip, Comment -AutoSize

# ---- CIM session (remote) ------------------------------------------------
$cimSess = $null
if (-not $Local) {
    if (-not $Credential) {
        $Credential = Get-Credential -Message "rtolab AD admin (e.g. rtolab\administrator)"
    }
    $opt = New-CimSessionOption -Protocol Wsman
    $cimSess = New-CimSession -ComputerName $DnsServer -Credential $Credential -SessionOption $opt -Authentication Negotiate
}
$zoneArgs = @{}
if ($cimSess) { $zoneArgs.CimSession = $cimSess }

# ---- Forward zone ---------------------------------------------------------
$zone = $null
try { $zone = Get-DnsServerZone -Name $ZoneName @zoneArgs -ErrorAction Stop } catch {}
if (-not $zone) {
    Write-Host "Zone $ZoneName 不存在, 建立 (Primary, AD-integrated, secure dynamic)..." -ForegroundColor Yellow
    if ($PSCmdlet.ShouldProcess($ZoneName, 'Add-DnsServerPrimaryZone')) {
        Add-DnsServerPrimaryZone -Name $ZoneName -ReplicationScope Domain -DynamicUpdate Secure @zoneArgs
    }
}

# ---- Reverse zones --------------------------------------------------------
function Get-ReverseZoneName {
    param([string]$Ip)
    $o = $Ip.Split('.')
    return "$($o[2]).$($o[1]).$($o[0]).in-addr.arpa"
}
function Get-PtrName { param([string]$Ip) return ($Ip.Split('.'))[3] }

$reverseZones = $records | ForEach-Object { Get-ReverseZoneName $_.Ip } | Sort-Object -Unique
Write-Host ""
Write-Host "Reverse zones 需要: $($reverseZones -join ', ')" -ForegroundColor Cyan
foreach ($rz in $reverseZones) {
    $existing = $null
    try { $existing = Get-DnsServerZone -Name $rz @zoneArgs -ErrorAction Stop } catch {}
    if (-not $existing) {
        $parts = $rz.Replace('.in-addr.arpa','').Split('.')
        [array]::Reverse($parts)
        $netId = "$($parts -join '.').0/24"
        Write-Host "  reverse zone $rz 不存在, 建 ($netId, Primary, AD-integrated)..." -ForegroundColor Yellow
        if ($PSCmdlet.ShouldProcess($rz, 'Add-DnsServerPrimaryZone (reverse)')) {
            Add-DnsServerPrimaryZone -NetworkId $netId -ReplicationScope Domain -DynamicUpdate Secure @zoneArgs
        }
    } else {
        Write-Host "  reverse zone ${rz}: 已存在" -ForegroundColor DarkGray
    }
}

# ---- 套用 Forward A ------------------------------------------------------
Write-Host ""
Write-Host "Forward A 記錄:" -ForegroundColor Cyan
foreach ($r in $records) {
    $existing = $null
    try { $existing = Get-DnsServerResourceRecord -ZoneName $ZoneName -Name $r.Name -RRType A @zoneArgs -ErrorAction Stop } catch {}
    if ($existing) {
        $curIp = $existing.RecordData.IPv4Address.IPAddressToString
        if ($curIp -eq $r.Ip) {
            Write-Host "  [skip] $($r.Name) -> $($r.Ip)" -ForegroundColor DarkGray
            continue
        }
        Write-Host "  [update] $($r.Name): $curIp -> $($r.Ip)" -ForegroundColor Yellow
        if ($PSCmdlet.ShouldProcess("$($r.Name).$ZoneName -> $($r.Ip)", 'Update A')) {
            Remove-DnsServerResourceRecord -ZoneName $ZoneName -InputObject $existing -Force @zoneArgs
            Add-DnsServerResourceRecordA -ZoneName $ZoneName -Name $r.Name -IPv4Address $r.Ip @zoneArgs
        }
    } else {
        Write-Host "  [add]  $($r.Name) -> $($r.Ip)" -ForegroundColor Green
        if ($PSCmdlet.ShouldProcess("$($r.Name).$ZoneName -> $($r.Ip)", 'Add A')) {
            Add-DnsServerResourceRecordA -ZoneName $ZoneName -Name $r.Name -IPv4Address $r.Ip @zoneArgs
        }
    }
}

# ---- 套用 Reverse PTR ----------------------------------------------------
Write-Host ""
Write-Host "Reverse PTR 記錄:" -ForegroundColor Cyan
foreach ($r in $records) {
    $rzName  = Get-ReverseZoneName $r.Ip
    $ptrName = Get-PtrName $r.Ip
    $expectedPtr = "$($r.Name).$ZoneName."
    $existing = $null
    try { $existing = Get-DnsServerResourceRecord -ZoneName $rzName -Name $ptrName -RRType Ptr @zoneArgs -ErrorAction Stop } catch {}
    if ($existing) {
        $curPtr = $existing.RecordData.PtrDomainName
        if ($curPtr -eq $expectedPtr) {
            Write-Host "  [skip] $ptrName.$rzName -> $expectedPtr" -ForegroundColor DarkGray
            continue
        }
        Write-Host "  [update] $ptrName.$rzName : $curPtr -> $expectedPtr" -ForegroundColor Yellow
        if ($PSCmdlet.ShouldProcess("$ptrName.$rzName -> $expectedPtr", 'Update PTR')) {
            Remove-DnsServerResourceRecord -ZoneName $rzName -InputObject $existing -Force @zoneArgs
            Add-DnsServerResourceRecordPtr -ZoneName $rzName -Name $ptrName -PtrDomainName $expectedPtr @zoneArgs
        }
    } else {
        Write-Host "  [add]  $ptrName.$rzName -> $expectedPtr" -ForegroundColor Green
        if ($PSCmdlet.ShouldProcess("$ptrName.$rzName -> $expectedPtr", 'Add PTR')) {
            Add-DnsServerResourceRecordPtr -ZoneName $rzName -Name $ptrName -PtrDomainName $expectedPtr @zoneArgs
        }
    }
}

# ---- Legacy cleanup ------------------------------------------------------
if ($CleanupLegacy) {
    Write-Host ""
    Write-Host "Legacy cleanup (移除舊 short FQDN):" -ForegroundColor Cyan
    $legacyA = @(
        'sddc-mgr','vc-mgmt','nsx-mgmt','nsx-mgmt-01',
        'vcf-inst-90','vcf-inst-91','vcf-cb',
        'vcf-ops','vcf-fleet','vcf-coll',
        'esx01','esx02','esx03','esx04'
    )
    foreach ($name in $legacyA) {
        $rec = $null
        try { $rec = Get-DnsServerResourceRecord -ZoneName $ZoneName -Name $name -RRType A @zoneArgs -ErrorAction Stop } catch {}
        if (-not $rec) { continue }
        $ip = $rec.RecordData.IPv4Address.IPAddressToString
        Write-Host "  [remove A]   $name.$ZoneName -> $ip" -ForegroundColor Red
        if ($PSCmdlet.ShouldProcess("$name.$ZoneName -> $ip", 'Remove legacy A')) {
            Remove-DnsServerResourceRecord -ZoneName $ZoneName -InputObject $rec -Force @zoneArgs
        }
        # 對應 PTR 也清
        $rz = Get-ReverseZoneName $ip
        $ptr = Get-PtrName $ip
        $ptrRec = $null
        try { $ptrRec = Get-DnsServerResourceRecord -ZoneName $rz -Name $ptr -RRType Ptr @zoneArgs -ErrorAction Stop } catch {}
        if ($ptrRec -and $ptrRec.RecordData.PtrDomainName -like "$name.*") {
            Write-Host "  [remove PTR] $ptr.$rz -> $($ptrRec.RecordData.PtrDomainName)" -ForegroundColor Red
            if ($PSCmdlet.ShouldProcess("$ptr.$rz", 'Remove legacy PTR')) {
                Remove-DnsServerResourceRecord -ZoneName $rz -InputObject $ptrRec -Force @zoneArgs
            }
        }
    }
}

if ($cimSess) { Remove-CimSession $cimSess }
Write-Host ""
Write-Host "完成. 驗證:" -ForegroundColor Cyan
Write-Host "  Resolve-DnsName -Server $DnsServer kosten-vcf90-sddc.$ZoneName"
Write-Host "  Resolve-DnsName -Server $DnsServer 192.168.114.35 -Type PTR"
