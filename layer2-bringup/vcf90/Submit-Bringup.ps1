<#
.SYNOPSIS
    Push VCF 9.0 bring-up JSON 到 VCF Installer (JWT Bearer auth).
    Self-contained for 9.0; user 預設 admin@local, env VCF_INSTALLER_PW.

.PARAMETER VcfInstaller
    VCF Installer URL, 例如 https://192.168.114.34
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)] [string] $VcfInstaller,
    [string] $SpecFile = './generated-bringup.json',
    [string] $User = 'admin@local',
    [switch] $ValidateOnly,
    [int]    $PollInterval = 60,
    [string] $Token
)

$ErrorActionPreference = 'Stop'
$Version = '9.0'
if (-not (Test-Path $SpecFile)) { throw "Spec 檔不存在: $SpecFile" }
$specJson = Get-Content -Raw $SpecFile

if (-not ('TrustAllCertsPolicy' -as [type])) {
    Add-Type -TypeDefinition @'
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
        public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
    }
'@
}
[System.Net.ServicePointManager]::CertificatePolicy = [TrustAllCertsPolicy]::new()
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$base = $VcfInstaller.TrimEnd('/')

# ---- Auth: POST /v1/tokens 拿 JWT ----------------------------------------
if (-not $Token) {
    Write-Host "登入 $base (VCF Installer 9.0)..."
    $pw = if ($env:VCF_INSTALLER_PW) { $env:VCF_INSTALLER_PW } else {
        Read-Host -AsSecureString "Password for $User" | ConvertFrom-SecureString -AsPlainText
    }
    $authBody = @{ username = $User; password = $pw } | ConvertTo-Json
    $authResp = Invoke-RestMethod -Uri "$base/v1/tokens" -Method Post -Body $authBody `
                  -ContentType 'application/json' -SkipCertificateCheck
    $Token = $authResp.accessToken
    if (-not $Token) { throw "登入失敗, 回應沒有 accessToken" }
    Write-Host "  -> Token 取到"
}
$headers = @{ 'Authorization' = "Bearer $Token"; 'Content-Type' = 'application/json' }

# ---- Validation ----------------------------------------------------------
Write-Host ""
Write-Host "送 validation..." -ForegroundColor Cyan
$valResp = Invoke-RestMethod -Uri "$base/v1/sddcs/validations" -Method Post -Headers $headers -Body $specJson -SkipCertificateCheck
$valId = $valResp.id
do {
    Start-Sleep 10
    $v = Invoke-RestMethod -Uri "$base/v1/sddcs/validations/$valId" -Headers $headers -SkipCertificateCheck
    Write-Host ("  status: {0}" -f $v.executionStatus)
} while ($v.executionStatus -in @('IN_PROGRESS','PENDING'))

if ($v.executionStatus -ne 'COMPLETED' -or $v.resultStatus -ne 'SUCCEEDED') {
    Write-Host "Validation FAILED:" -ForegroundColor Red
    $v.validationChecks | Where-Object { $_.resultStatus -ne 'SUCCEEDED' } | Select-Object description, resultStatus, errorResponse | Format-List
    throw "Validation 沒過. 修 spec 或加 -LabMode 重產."
}
Write-Host "Validation OK ✓" -ForegroundColor Green
if ($ValidateOnly) { return }

# ---- Bring-up ------------------------------------------------------------
Write-Host ""
Write-Host "送 bring-up..." -ForegroundColor Cyan
$bringupResp = Invoke-RestMethod -Uri "$base/v1/sddcs" -Method Post -Headers $headers -Body $specJson -SkipCertificateCheck
$sddcId = $bringupResp.id
Write-Host "  sddcId: $sddcId; poll 每 $PollInterval 秒..."

$lastPct = -1; $lastSt = ''
do {
    Start-Sleep $PollInterval
    $s = Invoke-RestMethod -Uri "$base/v1/sddcs/$sddcId" -Headers $headers -SkipCertificateCheck
    $pct = $s.completionPercent; $st = $s.status
    if ($pct -ne $lastPct -or $st -ne $lastSt) {
        $stage = if ($s.currentStage) { $s.currentStage.name } else { '' }
        Write-Host ("  [{0,3}%] {1,-12} {2}" -f $pct, $st, $stage)
        $lastPct = $pct; $lastSt = $st
    }
} while ($st -in @('IN_PROGRESS','PENDING','RUNNING'))

if ($st -eq 'COMPLETED' -or $s.resultStatus -eq 'SUCCESS') {
    Write-Host ""
    Write-Host "🎉 VCF 9.0 Bring-up SUCCESS" -ForegroundColor Green
    Write-Host "  SDDC Manager: $($s.sddcManagerSpec.hostname)"
    Write-Host "  vCenter:      $($s.vcenterSpec.vcenterHostname)"
} else {
    Write-Host "Bring-up FAILED. Status=$st" -ForegroundColor Red
    Write-Host "  Logs: Invoke-RestMethod -Uri '$base/v1/sddcs/$sddcId/logs' -Headers `$headers"
    exit 1
}
