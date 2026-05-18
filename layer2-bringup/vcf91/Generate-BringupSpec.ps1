<#
.SYNOPSIS
    VCF 9.1 bring-up spec generator (self-contained, no -Version param).
    讀 inventory/lab.yaml 的 9.1 區塊 + secrets/lab.yaml, 渲染 bringup.template.json,
    輸出 generated-bringup.json. 套用 9.1 lab workaround (skipChecks 陣列).

.PARAMETER LabMode
    啟用 9.1 lab workaround: skipChecks = [NESTED_CPU_CHECK, NIC_COUNT_CHECK,
    MIN_HOST_CHECK, VSAN_ESA_HCL_CHECK, ESX_THUMBPRINT_CHECK].
#>

[CmdletBinding()]
param(
    [string] $OutputFile = './generated-bringup.json',
    [switch] $LabMode
)

$ErrorActionPreference = 'Stop'
$Version = '9.1'
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

Write-Host "VCF 版本: $Version (vcf91 self-contained)"
Write-Host "使用 template: $TemplateFile"

$inv     = Get-Content -Raw $InventoryFile | ConvertFrom-Yaml
$secrets = Get-Content -Raw $SecretsFile   | ConvertFrom-Yaml

foreach ($k in 'esxi.root_pw','outer_vcenter.sso_admin_pw','inner_vcenter.sso_admin_pw',
                'sddc_manager.admin_pw','sddc_manager.root_pw','nsx.admin_pw',
                'deploy_defaults.vm_root_pw') {
    $parts = $k -split '\.'
    $v = $secrets
    foreach ($p in $parts) { $v = if ($v -is [hashtable]) { $v[$p] } else { $v.$p } }
    if (-not $v) { throw "secrets 缺值: $k (VCF 9.1 必填)" }
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

# ---- 9.1 Lab workarounds (skipChecks 陣列) -------------------------------
if ($LabMode) {
    Write-Host "套用 9.1 LabMode workarounds (skipChecks 陣列)..."
    if (-not $parsed.PSObject.Properties['skipChecks']) {
        $parsed | Add-Member -NotePropertyName skipChecks -NotePropertyValue @()
    }
    $parsed.skipChecks = @(
        'NESTED_CPU_CHECK',
        'NIC_COUNT_CHECK',
        'MIN_HOST_CHECK',
        'VSAN_ESA_HCL_CHECK',
        'ESX_THUMBPRINT_CHECK'
    )
    if ($parsed.vsanSpec.esaConfig.enabled -eq $true) {
        Write-Host "  (留 vSAN ESA enabled = true, 改用 skipChecks 繞 HCL)"
    }
}

$parsed | ConvertTo-Json -Depth 30 | Set-Content -Path $OutputFile -Encoding UTF8
Write-Host ""
Write-Host "==> $OutputFile" -ForegroundColor Green
Write-Host "    $(((Get-Item $OutputFile).Length)/1KB) KB"
Write-Host ""
Write-Host "下一步: pwsh .\Submit-Bringup.ps1 -VcfInstaller https://<installer-ip>"
