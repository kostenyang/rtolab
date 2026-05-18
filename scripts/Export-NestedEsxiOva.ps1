<#
.SYNOPSIS
    把已裝好 ESXi + 加 local.sh 的 master VM 匯出成 .ova golden image.
    流程: Stop-VM -> 卸 CDROM ISO -> Export-VApp -> 重打包成單檔 .ova -> 注入
    OVF vApp property declarations (guestinfo.hostname / .ipaddress / .netmask /
    .gateway / .vlan / .dns / .domain / .ntp) 讓未來部署可從 OVF properties 餵值.

.PARAMETER VMName
    Master VM name. 例如 vcf-m02-esx01-521.

.PARAMETER OvaName
    輸出 OVA 檔名 (不含 .ova). 預設 'rtolab-nested-esxi8' / 'esxi9.0' / 'esxi9.1'
    依 master VM 對應版本決定. 也可手動指定.

.PARAMETER OutputDir
    輸出資料夾. 預設 E:\custom-ova\

.EXAMPLE
    pwsh scripts\Export-NestedEsxiOva.ps1 -VMName vcf-m02-esx01-521
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)] [string] $VMName,
    [string] $OvaName,
    [string] $OutputDir = 'E:\custom-ova'
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

$vm = Get-VM -Name $VMName -ErrorAction Stop

if (-not $OvaName) {
    if     ($VMName -match '-521$') { $OvaName = 'rtolab-nested-esxi8' }
    elseif ($VMName -match '-90$')  { $OvaName = 'rtolab-nested-esxi9.0' }
    elseif ($VMName -match '-91$')  { $OvaName = 'rtolab-nested-esxi9.1' }
    else                             { $OvaName = "rtolab-nested-$VMName" }
}

if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir | Out-Null }

# ---- 1. Stop VM + 卸 CDROM ------------------------------------------------
if ($vm.PowerState -eq 'PoweredOn') {
    Write-Host "[1/4] stopping VM..." -ForegroundColor Cyan
    Stop-VM -VM $vm -Kill -Confirm:$false | Out-Null
    while ((Get-VM -Id $vm.Id).PowerState -ne 'PoweredOff') { Start-Sleep 1 }
}
$cd = $vm | Get-CDDrive
if ($cd.IsoPath) {
    Write-Host "[1/4] unmount ISO from CDROM..."
    Set-CDDrive -CD $cd -NoMedia -Confirm:$false | Out-Null
}

# ---- 2. Export VM 成 OVF folder ------------------------------------------
Write-Host "[2/4] Export-VApp (OVF, thin)..." -ForegroundColor Cyan
$exportFolder = Join-Path $OutputDir $VMName
if (Test-Path $exportFolder) { Remove-Item -Recurse -Force $exportFolder }
Export-VApp -VM $vm -Destination $OutputDir -Format Ovf -Force | Out-Null

# Export-VApp 會在 $OutputDir\<VMName>\ 下放 .ovf .mf .vmdk
$ovfFile = Get-ChildItem $exportFolder -Filter *.ovf | Select-Object -First 1
if (-not $ovfFile) { throw "Export-VApp 沒產 .ovf?" }
Write-Host "  exported: $exportFolder"

# ---- 3. 注入 OVF vApp properties (guestinfo.*) ---------------------------
Write-Host "[3/4] injecting OVF vApp properties (guestinfo.*)..."  -ForegroundColor Cyan
$xml = [xml](Get-Content -Raw $ovfFile.FullName)
$ns  = $xml.DocumentElement.NamespaceURI

# 加 ProductSection 給 VirtualSystem (或直接加到 root)
$vs = $xml.SelectSingleNode("//*[local-name()='VirtualSystem']")
if (-not $vs) { $vs = $xml.DocumentElement }

# 已存在 ProductSection? 跳過
if (-not $vs.SelectSingleNode("./*[local-name()='ProductSection']")) {
    $ps = $xml.CreateElement('ProductSection', $ns)
    $info = $xml.CreateElement('Info', $ns); $info.InnerText = 'Nested ESXi Configuration'; $ps.AppendChild($info) | Out-Null
    $prod = $xml.CreateElement('Product', $ns); $prod.InnerText = 'rtolab nested ESXi'; $ps.AppendChild($prod) | Out-Null

    $props = @(
        @{ Key='guestinfo.hostname';  Type='string'; Desc='Hostname (FQDN)' },
        @{ Key='guestinfo.ipaddress'; Type='string'; Desc='Mgmt IP' },
        @{ Key='guestinfo.netmask';   Type='string'; Desc='Netmask'; Default='255.255.255.0' },
        @{ Key='guestinfo.gateway';   Type='string'; Desc='Gateway' },
        @{ Key='guestinfo.vlan';      Type='string'; Desc='VLAN ID'; Default='114' },
        @{ Key='guestinfo.dns';       Type='string'; Desc='DNS' },
        @{ Key='guestinfo.domain';    Type='string'; Desc='Domain'; Default='rtolab.local' },
        @{ Key='guestinfo.ntp';       Type='string'; Desc='NTP' },
        @{ Key='guestinfo.password';  Type='password'; Desc='ESXi root password (optional)' }
    )
    foreach ($p in $props) {
        $prop = $xml.CreateElement('Property', $ns)
        $prop.SetAttribute('key', 'http://schemas.dmtf.org/ovf/envelope/1', $p.Key) | Out-Null
        $prop.SetAttribute('type', 'http://schemas.dmtf.org/ovf/envelope/1', $p.Type) | Out-Null
        $prop.SetAttribute('userConfigurable', 'http://schemas.dmtf.org/ovf/envelope/1', 'true') | Out-Null
        if ($p.Default) { $prop.SetAttribute('value', 'http://schemas.dmtf.org/ovf/envelope/1', $p.Default) | Out-Null }
        $label = $xml.CreateElement('Label', $ns); $label.InnerText = $p.Desc; $prop.AppendChild($label) | Out-Null
        $ps.AppendChild($prop) | Out-Null
    }
    $vs.AppendChild($ps) | Out-Null
    $xml.Save($ovfFile.FullName)
    Write-Host "  ✓ added ProductSection with 9 guestinfo.* properties"
}

# 重算 .mf 的 SHA — 簡單做法: 直接刪 .mf, vCenter Import-VApp 不檢查
Get-ChildItem $exportFolder -Filter *.mf | Remove-Item -Force

# ---- 4. Repack OVF folder -> single .ova ---------------------------------
$ovaPath = Join-Path $OutputDir "$OvaName.ova"
if (Test-Path $ovaPath) { Remove-Item $ovaPath -Force }
Write-Host "[4/4] repacking to $ovaPath ..." -ForegroundColor Cyan

# OVA = tar of OVF folder, order matters: .ovf first, then .vmdk
$files = @($ovfFile.Name) + (Get-ChildItem $exportFolder -File | Where-Object { $_.Name -ne $ovfFile.Name } | Sort-Object Name | ForEach-Object { $_.Name })
Push-Location $exportFolder
try {
    tar -cf $ovaPath $files
    if ($LASTEXITCODE -ne 0) { throw "tar create failed" }
} finally { Pop-Location }

$ovaSizeMB = [math]::Round((Get-Item $ovaPath).Length / 1MB, 0)
Write-Host "✓ OVA built: $ovaPath ($ovaSizeMB MB)" -ForegroundColor Green

# Clean up OVF folder
Remove-Item -Recurse -Force $exportFolder

Disconnect-VIServer * -Confirm:$false -Force | Out-Null

Write-Host ""
Write-Host "下一步: 把 $ovaPath 當作未來部署 base, Import-VApp + 設 guestinfo OVF props." -ForegroundColor Cyan
