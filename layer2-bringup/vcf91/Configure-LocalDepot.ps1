<#
.SYNOPSIS
    把 VCF Installer 9.1 接到 jumpbox 本機的 offline VCF software depot.

.DESCRIPTION
    9.1 native 支援 HTTP no-auth offline depot (William Lam, 2026-05).
    這隻 script:
    1. 起 nginx (jumpbox 已有的) 或 Python http.server 服務 E:\vcf-depot-91 on HTTP 8888
    2. POST /v1/system/depot-config 到 installer, 把 depot URL 接上
    3. Re-run validation 應該過 "Versions and Bundles"

.PARAMETER InstallerUrl
    VCF Installer URL. 預設 https://192.168.114.5
.PARAMETER DepotRoot
    本機 depot path. 預設 E:\vcf-depot-91
.PARAMETER DepotPort
    HTTP port. 預設 8888
.PARAMETER JumpboxIp
    Jumpbox IP (從 installer 那邊看). 預設 172.16.10.32
#>
[CmdletBinding()]
param(
    [string] $InstallerUrl = 'https://192.168.114.5',
    [string] $DepotRoot    = 'E:\vcf-depot-91',
    [int]    $DepotPort    = 8888,
    [string] $JumpboxIp    = '172.16.10.32'
)
$ErrorActionPreference = 'Stop'

$prodPath = Join-Path $DepotRoot 'PROD'
if (-not (Test-Path $prodPath)) { throw "Depot $prodPath 不存在, 還沒下載完?" }

# ---- 1. 確認 depot 有 manifest + 主要 component ---------------------------
$manifest = Join-Path $prodPath 'metadata\manifest\v1\vcfManifest.json'
if (-not (Test-Path $manifest)) { throw "缺 manifest: $manifest" }
$comp = Join-Path $prodPath 'COMP'
Write-Host "Depot components present:" -ForegroundColor Cyan
Get-ChildItem $comp -Directory | ForEach-Object {
    $files = Get-ChildItem $_.FullName -File -Recurse | Where-Object { $_.Length -gt 1MB }
    $size = ($files | Measure-Object Length -Sum).Sum / 1MB
    Write-Host ("  {0,-22} {1,3} file(s) {2,8:N0} MB" -f $_.Name, $files.Count, $size)
}
Write-Host ""

# ---- 2. 起 HTTP server on $DepotPort serving $DepotRoot\PROD ---------------
# 簡單做法: python3 http.server 或 powershell Listener.
# 因 Windows Server 2022 可能沒 python, 用 PowerShell HttpListener.
$serverScript = @"
`$listener = New-Object System.Net.HttpListener
`$listener.Prefixes.Add('http://+:$DepotPort/')
`$listener.Start()
Write-Host "Depot server listening on http://+:$DepotPort/ -> $prodPath"
while (`$listener.IsListening) {
    try {
        `$ctx = `$listener.GetContext()
        `$req = `$ctx.Request
        `$resp = `$ctx.Response
        `$path = `$req.Url.LocalPath -replace '^/',''
        `$file = Join-Path '$prodPath' (`$path -replace '/','\')
        if (Test-Path `$file -PathType Leaf) {
            `$bytes = [IO.File]::ReadAllBytes(`$file)
            `$resp.ContentLength64 = `$bytes.Length
            `$resp.OutputStream.Write(`$bytes, 0, `$bytes.Length)
            `$resp.StatusCode = 200
        } else {
            `$resp.StatusCode = 404
        }
        `$resp.Close()
    } catch { Write-Warning "`$_" }
}
"@
# 寫到 tmp 並啟動 detached
$serverFile = Join-Path $env:TEMP 'vcf-depot-server.ps1'
Set-Content -Path $serverFile -Value $serverScript -Encoding UTF8

# Firewall rule (idempotent)
$existing = Get-NetFirewallRule -DisplayName "VCF Depot HTTP $DepotPort" -ErrorAction SilentlyContinue
if (-not $existing) {
    New-NetFirewallRule -DisplayName "VCF Depot HTTP $DepotPort" -Direction Inbound -Protocol TCP -LocalPort $DepotPort -Action Allow | Out-Null
    Write-Host "  [+] Firewall opened for TCP/$DepotPort"
}

# Spawn server (admin needed for HttpListener wildcard binding; if fails fall back to specific binding)
Write-Host "Starting depot HTTP server (PowerShell HttpListener)..."
$proc = Start-Process pwsh -ArgumentList '-NoProfile','-File',$serverFile -WindowStyle Hidden -PassThru
Start-Sleep 3
# Verify
try {
    $r = Invoke-WebRequest -Uri "http://${JumpboxIp}:${DepotPort}/metadata/manifest/v1/vcfManifest.json" -UseBasicParsing -TimeoutSec 5
    Write-Host "  [✓] Depot serving — HTTP $($r.StatusCode), $($r.Content.Length) B" -ForegroundColor Green
} catch {
    Write-Warning "  Depot HTTP not serving: $($_.Exception.Message)"
    Write-Host "  (continue and try installer config; if it fails, fix server first)"
}

# ---- 3. POST /v1/system/depot-config to installer -------------------------
$body = @{ username = 'admin@local'; password = 'VMware1!VMware1!' } | ConvertTo-Json
$tk = (Invoke-RestMethod -Uri "$InstallerUrl/v1/tokens" -Method Post -Body $body -ContentType 'application/json' -SkipCertificateCheck).accessToken
$h = @{ 'Authorization' = "Bearer $tk"; 'Content-Type' = 'application/json' }

# 9.1 HTTP-no-auth depot config schema (per Lam's blog 2026-05 + openapi)
$depotConfig = @{
    vmwareAccount = $null
    offlineDepotConfigs = @(
        @{
            url = "http://${JumpboxIp}:${DepotPort}/"
            offlineDepotType = "DEFAULT"
            credentials = $null
        }
    )
} | ConvertTo-Json -Depth 5

Write-Host ""
Write-Host "Posting depot config to installer..."
Write-Host "  URL: http://${JumpboxIp}:${DepotPort}/"
try {
    $r = Invoke-RestMethod -Uri "$InstallerUrl/v1/system/depot-config" -Method Put -Headers $h -Body $depotConfig -SkipCertificateCheck
    Write-Host "  ✓ depot config set" -ForegroundColor Green
    $r | ConvertTo-Json -Depth 5
} catch {
    Write-Host "  Depot config error:"
    Write-Host $_.ErrorDetails.Message
}

Write-Host ""
Write-Host "下一步: 跑 Submit-Bringup.ps1 -ValidateOnly 再驗 'Versions and Bundles'"
