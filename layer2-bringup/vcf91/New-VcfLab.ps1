<#
.SYNOPSIS
    一鍵 VCF 9.1 bring-up — wrapper: Generate spec -> Validate -> 確認 -> Bring up.

.EXAMPLE
    pwsh .\New-VcfLab.ps1 -VcfInstaller https://192.168.114.5
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)] [string] $VcfInstaller,
    [switch] $NonInteractive,
    [switch] $SkipLabMode
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$specFile = Join-Path $here 'generated-bringup.json'

Write-Host "=== Step 1/3: 產生 VCF 9.1 bring-up spec ==="
$genArgs = @{ OutputFile = $specFile }
if (-not $SkipLabMode) { $genArgs.LabMode = $true }
& (Join-Path $here 'Generate-BringupSpec.ps1') @genArgs

Write-Host ""
Write-Host "=== Step 2/3: Validation only ==="
& (Join-Path $here 'Submit-Bringup.ps1') -VcfInstaller $VcfInstaller -SpecFile $specFile -ValidateOnly

if (-not $NonInteractive) {
    Write-Host ""
    Write-Host "Validation 過了. 真的要送 VCF 9.1 bring-up 嗎? (約 1-2 小時)" -ForegroundColor Yellow
    $ans = Read-Host "輸入 'YES' 繼續, 其他結束"
    if ($ans -ne 'YES') { Write-Host "取消."; return }
}

Write-Host ""
Write-Host "=== Step 3/3: Bring-up ==="
& (Join-Path $here 'Submit-Bringup.ps1') -VcfInstaller $VcfInstaller -SpecFile $specFile

Write-Host ""
Write-Host "完成. 接下來建議跑 layer3-postbringup/ 的 commission / domain 腳本."
