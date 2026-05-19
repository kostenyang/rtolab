<#
.SYNOPSIS
    Push VCF 5.2.1 bring-up JSON 到 Cloud Builder (HTTP Basic Auth).
    Self-contained for 5.2.1; user 預設 admin, env CB_ADMIN_PW.

.PARAMETER CloudBuilder
    Cloud Builder URL, 例如 https://192.168.114.54
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)] [string] $CloudBuilder,
    [string] $SpecFile = './generated-bringup.json',
    [string] $User = 'admin',
    [switch] $ValidateOnly,
    [int]    $PollInterval = 60
)

$ErrorActionPreference = 'Stop'
$Version = '5.2.1'
if (-not (Test-Path $SpecFile)) { throw "Spec 檔不存在: $SpecFile" }
$specJson = Get-Content -Raw $SpecFile

# pwsh 7 沒 ICertificatePolicy. 所有 Invoke-RestMethod 都帶 -SkipCertificateCheck.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$base = $CloudBuilder.TrimEnd('/')

# ---- Cloud Builder Basic Auth (每呼叫都帶) ---------------------------------
$pw = if ($env:CB_ADMIN_PW) { $env:CB_ADMIN_PW } else {
    Read-Host -AsSecureString "Cloud Builder password for $User" | ConvertFrom-SecureString -AsPlainText
}
$basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${User}:${pw}"))
$headers = @{ 'Authorization' = "Basic $basic"; 'Content-Type' = 'application/json' }
Write-Host "Cloud Builder $base, basic auth as $User"

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
    throw "Validation 沒過."
}
Write-Host "Validation OK ✓" -ForegroundColor Green
if ($ValidateOnly) { return }

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
    Write-Host "🎉 VCF 5.2.1 Bring-up SUCCESS" -ForegroundColor Green
} else {
    Write-Host "Bring-up FAILED. Status=$st" -ForegroundColor Red
    exit 1
}
