<#
.SYNOPSIS
    一鍵 VCF lab bring-up (9.0 / 9.1 / 5.2.1) — 從 inventory + secrets 一路打到 SDDC 起來.

.DESCRIPTION
    串起 layer2 的三步:
        1. Generate-BringupSpec.ps1     讀 inventory + secrets -> generated-bringup.json
        2. Submit-Bringup.ps1 -ValidateOnly   先 validation
        3. (人類確認) -> Submit-Bringup.ps1   真的 bring-up + poll

    預設啟用 -LabMode (跳過 nested CPU / vSAN ESA HCL / NIC count 等檢查).
    Version 從 -Version 參數讀, 沒給就讀 inventory 的 vcf.version, 還是沒有就預設 9.1.

.PARAMETER VcfInstaller
    VCF Installer URL (9.x) 或 Cloud Builder URL (5.2.1), 例如 https://192.168.114.5

.PARAMETER Version
    VCF 版本 ('9.0' / '9.1' / '5.2.1'). 不指定就讀 inventory/lab.yaml 的 vcf.version,
    再 fallback 到 9.1. 三版本用不同 template + 不同 lab workaround + 不同 auth (5.2.1 走 Basic Auth).

.PARAMETER NonInteractive
    跳過 validation 後的人類確認, 直接 bring-up. CI/CD 用.

.PARAMETER SkipLabMode
    不套用 lab workaround (正式環境用).

.EXAMPLE
    # VCF 9.1 (預設)
    pwsh ./New-VcfLab.ps1 -VcfInstaller https://192.168.114.5

.EXAMPLE
    # VCF 9.0
    pwsh ./New-VcfLab.ps1 -VcfInstaller https://192.168.114.34 -Version 9.0

.EXAMPLE
    # VCF 5.2.1 Cloud Builder
    pwsh ./New-VcfLab.ps1 -VcfInstaller https://192.168.114.54 -Version 5.2.1
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)] [string] $VcfInstaller,
    [ValidateSet('9.0','9.1','5.2.1','')] [string] $Version = '',
    [switch] $NonInteractive,
    [switch] $SkipLabMode
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "=== Step 1/3: 產生 bring-up spec ==="
# 預設讓 Generate-BringupSpec 自己用 sops 解密 inventory/secrets/lab.yaml
# 如果你想改成從 env vars 讀, 加 -SecretsAlreadyLoaded 並先 set env
$genArgs = @{
    OutputFile = (Join-Path $here 'generated-bringup.json')
}
if ($Version)        { $genArgs.Version = $Version }
if (-not $SkipLabMode) { $genArgs.LabMode = $true }
& (Join-Path $here 'Generate-BringupSpec.ps1') @genArgs

$submitCommon = @{
    VcfInstaller = $VcfInstaller
    SpecFile     = (Join-Path $here 'generated-bringup.json')
}
if ($Version) { $submitCommon.Version = $Version }

Write-Host ""
Write-Host "=== Step 2/3: Validation only ==="
& (Join-Path $here 'Submit-Bringup.ps1') @submitCommon -ValidateOnly

if (-not $NonInteractive) {
    Write-Host ""
    Write-Host "Validation 過了. 真的要送 bring-up 嗎? (約 1-2 小時)" -ForegroundColor Yellow
    $ans = Read-Host "輸入 'YES' 繼續, 其他結束"
    if ($ans -ne 'YES') {
        Write-Host "取消."
        return
    }
}

Write-Host ""
Write-Host "=== Step 3/3: Bring-up ==="
& (Join-Path $here 'Submit-Bringup.ps1') @submitCommon

Write-Host ""
Write-Host "完成. 接下來建議跑 layer3-postbringup/ 的 commission / domain 腳本."
