<#
.SYNOPSIS
    把產好的 bring-up JSON 推到 VCF Installer (9.x) 或 Cloud Builder (5.x) API,
    並 poll 狀態到完成 / 失敗.

.PARAMETER VcfInstaller
    VCF Installer URL (9.x) 或 Cloud Builder URL (5.x), 例如:
      https://192.168.114.5            (9.1 VCF Installer)
      https://vcf-inst-90.rtolab.local      (9.0 VCF Installer)
      https://vcf-cb.rtolab.local           (5.2.1 Cloud Builder)
    (不需要結尾斜線)

.PARAMETER SpecFile
    Generate-BringupSpec.ps1 產出的 JSON 檔.

.PARAMETER Version
    VCF 版本, 決定 auth 模式:
      9.0 / 9.1 -> POST /v1/tokens 拿 JWT, header 用 Bearer; user 預設 'admin@local'
      5.2.1     -> Basic Auth on every call (Cloud Builder); user 預設 'admin'
    沒指定就試圖從 SpecFile 內容判斷 (有 vcfInstanceName -> 9.0, sddcId+pscSpecs -> 5.2.1,
    sddcId without pscSpecs -> 9.1).

.PARAMETER User
    Admin 帳號. 預設 9.x = 'admin@local', 5.2.1 = 'admin'.

.PARAMETER ValidateOnly
    只送 validation, 不真的 bring-up.

.PARAMETER PollInterval
    Poll 間隔秒數, 預設 60.

.PARAMETER Token
    可選 (9.x): 已經拿到 JWT 的話直接傳, 跳過登入. (5.2.1 不適用 — basic auth 每呼叫帶)

.EXAMPLE
    # VCF 9.1 (或 9.0)
    pwsh ./Submit-Bringup.ps1 -VcfInstaller https://192.168.114.5 -SpecFile ./generated-bringup.json

.EXAMPLE
    # VCF 5.2.1 Cloud Builder
    pwsh ./Submit-Bringup.ps1 -VcfInstaller https://192.168.114.54 -SpecFile ./generated-bringup.json -Version 5.2.1

.NOTES
    9.x 端點: /v1/tokens (POST), /v1/sddcs/validations (POST), /v1/sddcs (POST), /v1/sddcs/{id} (GET).
    5.2.1 Cloud Builder 端點同名 (/v1/sddcs/validations, /v1/sddcs, /v1/sddcs/{id}) 但 auth 不同.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)] [string] $VcfInstaller,
    [Parameter(Mandatory=$true)] [string] $SpecFile,
    [ValidateSet('9.0','9.1','5.2.1','')] [string] $Version = '',
    [string] $User,
    [switch] $ValidateOnly,
    [int]    $PollInterval = 60,
    [string] $Token
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $SpecFile)) { throw "Spec 檔不存在: $SpecFile" }
$specJson = Get-Content -Raw $SpecFile

#---- 推斷 Version (如果沒給) -----------------------------------------------
if (-not $Version) {
    $specObj = $specJson | ConvertFrom-Json -Depth 30
    if ($specObj.pscSpecs) {
        $Version = '5.2.1'
    } elseif ($specObj.vcfInstanceName) {
        $Version = '9.0'
    } elseif ($specObj.sddcId) {
        $Version = '9.1'
    } else {
        throw "無法從 spec 推斷 Version, 請加 -Version 9.0|9.1|5.2.1"
    }
    Write-Host "從 spec 推斷 Version=$Version"
}

#---- 預設 User --------------------------------------------------------------
if (-not $User) {
    $User = if ($Version -eq '5.2.1') { 'admin' } else { 'admin@local' }
}

# Self-signed cert
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

#---------- 1. Auth -------------------------------------------------------
$headers = @{}
if ($Version -eq '5.2.1') {
    # Cloud Builder: Basic Auth 每呼叫都帶
    $pw = if ($env:CB_ADMIN_PW) { $env:CB_ADMIN_PW } else {
        Read-Host -AsSecureString "Cloud Builder password for $User" |
            ConvertFrom-SecureString -AsPlainText
    }
    $basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${User}:${pw}"))
    $headers = @{
        'Authorization' = "Basic $basic"
        'Content-Type'  = 'application/json'
    }
    Write-Host "Cloud Builder basic auth as $User"
} else {
    # VCF Installer (9.x): POST /v1/tokens 拿 JWT
    if (-not $Token) {
        Write-Host "登入 $base..."
        $pw = if ($env:VCF_INSTALLER_PW) { $env:VCF_INSTALLER_PW } else {
            Read-Host -AsSecureString "Password for $User" |
                ConvertFrom-SecureString -AsPlainText
        }
        $authBody = @{ username = $User; password = $pw } | ConvertTo-Json
        $authResp = Invoke-RestMethod -Uri "$base/v1/tokens" -Method Post -Body $authBody `
                      -ContentType 'application/json' -SkipCertificateCheck
        $Token = $authResp.accessToken
        if (-not $Token) { throw "登入失敗, 回應沒有 accessToken: $($authResp | ConvertTo-Json -Compress)" }
        Write-Host "  -> Token 取到"
    }
    $headers = @{
        'Authorization' = "Bearer $Token"
        'Content-Type'  = 'application/json'
    }
}

#---------- 2. Validation -------------------------------------------------
Write-Host ""
Write-Host "送 validation..." -ForegroundColor Cyan
$valResp = Invoke-RestMethod -Uri "$base/v1/sddcs/validations" -Method Post `
              -Headers $headers -Body $specJson -SkipCertificateCheck
$valId = $valResp.id
Write-Host "  validationId: $valId"

# Poll validation
do {
    Start-Sleep 10
    $v = Invoke-RestMethod -Uri "$base/v1/sddcs/validations/$valId" -Headers $headers -SkipCertificateCheck
    Write-Host ("  status: {0}" -f $v.executionStatus)
} while ($v.executionStatus -in @('IN_PROGRESS','PENDING'))

if ($v.executionStatus -ne 'COMPLETED' -or $v.resultStatus -ne 'SUCCEEDED') {
    Write-Host ""
    Write-Host "Validation FAILED. 詳細:" -ForegroundColor Red
    $v.validationChecks | Where-Object { $_.resultStatus -ne 'SUCCEEDED' } |
        Select-Object description, resultStatus, errorResponse |
        Format-List
    throw "Validation 沒過. 修 spec 或加 -LabMode 重產."
}
Write-Host "Validation OK ✓" -ForegroundColor Green

if ($ValidateOnly) {
    Write-Host "ValidateOnly 模式, 不送 bring-up. 結束."
    return
}

#---------- 3. Submit bring-up --------------------------------------------
Write-Host ""
Write-Host "送 bring-up..." -ForegroundColor Cyan
$bringupResp = Invoke-RestMethod -Uri "$base/v1/sddcs" -Method Post `
                  -Headers $headers -Body $specJson -SkipCertificateCheck
$sddcId = $bringupResp.id
Write-Host "  sddcId: $sddcId"
Write-Host "  task 已啟動, 開始 poll (每 $PollInterval 秒)..."

#---------- 4. Poll -------------------------------------------------------
$lastPct = -1
do {
    Start-Sleep $PollInterval
    $s = Invoke-RestMethod -Uri "$base/v1/sddcs/$sddcId" -Headers $headers -SkipCertificateCheck
    $pct = $s.completionPercent
    $st  = $s.status

    if ($pct -ne $lastPct -or $st -ne $lastSt) {
        $stage = if ($s.currentStage) { $s.currentStage.name } else { '' }
        Write-Host ("  [{0,3}%] {1,-12} {2}" -f $pct, $st, $stage)
        $lastPct = $pct
        $lastSt  = $st
    }
} while ($st -in @('IN_PROGRESS','PENDING','RUNNING'))

#---------- 5. Result -----------------------------------------------------
Write-Host ""
if ($st -eq 'COMPLETED' -or $s.resultStatus -eq 'SUCCESS') {
    Write-Host "🎉  Bring-up SUCCESS (Version=$Version)" -ForegroundColor Green
    Write-Host "  SDDC Manager : $($s.sddcManagerSpec.hostname)"
    Write-Host "  vCenter      : $($s.vcenterSpec.vcenterHostname)"
    Write-Host "  NSX VIP      : $($s.nsxtSpec.vip)"
} else {
    Write-Host "Bring-up FAILED. Status = $st" -ForegroundColor Red
    Write-Host "  到 $(if ($Version -eq '5.2.1') {'Cloud Builder'} else {'VCF Installer'}) UI 看詳細 log, 或:"
    Write-Host "  Invoke-RestMethod -Uri '$base/v1/sddcs/$sddcId/logs' -Headers `$headers"
    exit 1
}
