<#
.SYNOPSIS
    VCF 5.2.1 (Cloud Builder) bring-up spec generator (self-contained).
    讀 inventory/lab.yaml 的 5.2.1 區塊 + secrets/lab.yaml, 渲染 bringup.template.json.
    套用 5.2.1 lab workaround (skipEsxThumbprintValidation + deployWithoutLicenseKeys).
#>

[CmdletBinding()]
param(
    [string] $OutputFile = './generated-bringup.json',
    [switch] $LabMode
)

$ErrorActionPreference = 'Stop'
$Version = '5.2.1'
$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $here '../..')

if (-not (Get-Module -ListAvailable powershell-yaml)) {
    Install-Module powershell-yaml -Scope CurrentUser -Force | Out-Null
}
Import-Module powershell-yaml

$InventoryFile = Join-Path $repoRoot 'inventory/lab.yaml'
$SecretsFile   = Join-Path $repoRoot 'inventory/secrets/lab.yaml'
$TemplateFile  = Join-Path $here 'bringup.template.json'
foreach ($f in @($InventoryFile, $SecretsFile, $TemplateFile)) {
    if (-not (Test-Path $f)) { throw "找不到 $f" }
}

Write-Host "VCF 版本: $Version (vcf521 self-contained, Cloud Builder)"
Write-Host "使用 template: $TemplateFile"

$inv     = Get-Content -Raw $InventoryFile | ConvertFrom-Yaml
$secrets = Get-Content -Raw $SecretsFile   | ConvertFrom-Yaml

foreach ($k in 'esxi.root_pw','inner_vcenter.sso_admin_pw',
                'sddc_manager.admin_pw','sddc_manager.root_pw','nsx.admin_pw',
                'cloud_builder.admin_pw') {
    $parts = $k -split '\.'
    $v = $secrets
    foreach ($p in $parts) { $v = if ($v -is [hashtable]) { $v[$p] } else { $v.$p } }
    if (-not $v) { throw "secrets 缺值: $k (VCF 5.2.1 必填; cloud_builder.admin_pw 給 Submit basic auth 用)" }
}

$vBlock = $inv.vcf.versions[$Version]
if (-not $vBlock) { throw "inventory 沒有 vcf.versions['$Version']" }
$inv.vcf.management_domain = $vBlock.management_domain
$inv.network.vmotion.range_start = $vBlock.vmotion_range.start
$inv.network.vmotion.range_end   = $vBlock.vmotion_range.end
$inv.network.vsan.range_start    = $vBlock.vsan_range.start
$inv.network.vsan.range_end      = $vBlock.vsan_range.end
$inv.hosts = $inv.hosts_by_version[$Version]
if (@($inv.hosts).Count -lt 4) { throw "hosts_by_version['$Version'] 不滿 4 台" }

function Get-DeepValue { param($Obj, [string]$Path)
    $cur = $Obj
    foreach ($p in ($Path -split '\.|\[|\]' | Where-Object { $_ -ne '' })) {
        if ($null -eq $cur) { return $null }
        if ($p -match '^\d+$') { $cur = @($cur)[[int]$p] }
        elseif ($cur -is [hashtable]) { $cur = $cur[$p] }
        else { $cur = $cur.$p }
    }
    return $cur
}
function Resolve-Token { param([string]$Token, [hashtable]$Ctx)
    $segs = ($Token -split '\|').ForEach({ $_.Trim() })
    $val  = Get-DeepValue -Obj $Ctx -Path $segs[0]
    for ($i=1; $i -lt $segs.Count; $i++) {
        $f = $segs[$i]
        if     ($f -match "^default\s+'(.*)'$") { if ($null -eq $val -or "$val" -eq '') { $val = $matches[1] } }
        elseif ($f -match '^splitDot\s+(\d+)$') { if ($val) { $val = ($val -split '\.')[[int]$matches[1]] } }
        else { Write-Warning "未知 filter: $f" }
    }
    return $val
}

$ctx = @{ lab=$inv.lab; infra=$inv.infra; vcf=$inv.vcf; hosts=$inv.hosts; network=$inv.network; secrets=$secrets }
$rendered = Get-Content -Raw $TemplateFile
$rendered = [regex]::Replace($rendered, '\{\{\s*(.+?)\s*\}\}', {
    param($m)
    $v = Resolve-Token -Token $m.Groups[1].Value -Ctx $ctx
    if ($null -eq $v) { return '' }
    return ($v -replace '\\','\\\\' -replace '"','\\"')
}, 'IgnoreCase')

try {
    $parsed = $rendered | ConvertFrom-Json -Depth 30
} catch {
    Set-Content -Path "$OutputFile.broken.json" -Value $rendered -Encoding UTF8
    throw "渲染後 JSON parse 失敗, 結果存 $OutputFile.broken.json. Error: $_"
}

# ---- 5.2.1 Lab workarounds (Cloud Builder, 旗標散在各 spec 內) ------------
if ($LabMode) {
    Write-Host "套用 5.2.1 LabMode workarounds..."
    $parsed.skipEsxThumbprintValidation = $true
    $parsed.deployWithoutLicenseKeys    = $true
    $parsed.ceipEnabled                 = $false
    # template 已預設 excludedComponents = ['AVN','EBGP'] (不部署 AVN/Edge BGP)
}

$parsed | ConvertTo-Json -Depth 30 | Set-Content -Path $OutputFile -Encoding UTF8
Write-Host ""
Write-Host "==> $OutputFile" -ForegroundColor Green
Write-Host "    $(((Get-Item $OutputFile).Length)/1KB) KB"
Write-Host ""
Write-Host "下一步: pwsh .\Submit-Bringup.ps1 -CloudBuilder https://<cb-ip>"
