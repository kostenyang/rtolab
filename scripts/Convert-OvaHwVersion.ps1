<#
.SYNOPSIS
    Hand-edit OVA's OVF descriptor to downgrade <vssd:VirtualSystemType> from
    vmx-20 → vmx-19 so it can deploy on vSphere 7.0u3 (max vmx-19).
    用 Windows 內建 tar.exe (bsdtar) 解包、改 .ovf、重打包 (不重算 .mf signature,
    所以把 .mf 拿掉避免 vCenter SHA mismatch).

.PARAMETER Source
    來源 OVA 完整路徑.

.PARAMETER Dest
    輸出 OVA 完整路徑. 預設 = source 同資料夾, 檔名加 -vmx19.

.PARAMETER TargetHwVersion
    目標 hardware version. 預設 19 (vSphere 7.0u3 max).

.EXAMPLE
    pwsh .\Convert-OvaHwVersion.ps1 -Source E:\9.0\Nested_ESXi9.0.2_Appliance_Template_v1.0.ova
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)] [string] $Source,
    [string] $Dest,
    [int]    $TargetHwVersion = 19
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Source)) { throw "Source 不存在: $Source" }
if (-not $Dest) {
    $dir  = Split-Path -Parent $Source
    $name = [IO.Path]::GetFileNameWithoutExtension($Source)
    $Dest = Join-Path $dir "$name-vmx$TargetHwVersion.ova"
}
if (Test-Path $Dest) {
    Write-Host "Dest 已存在, 跳過: $Dest" -ForegroundColor DarkGray
    return $Dest
}

$tmp = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "ova-$([Guid]::NewGuid().ToString('N'))")
try {
    Write-Host "[1/4] extracting $Source -> $($tmp.FullName)" -ForegroundColor Cyan
    tar -xf $Source -C $tmp.FullName
    if ($LASTEXITCODE -ne 0) { throw "tar extract failed" }

    $ovfFile = Get-ChildItem $tmp.FullName -Filter *.ovf | Select-Object -First 1
    if (-not $ovfFile) { throw "No .ovf in $Source" }

    Write-Host "[2/4] editing $($ovfFile.Name): vmx-20 -> vmx-$TargetHwVersion" -ForegroundColor Cyan
    $content = [System.IO.File]::ReadAllText($ovfFile.FullName)
    $newContent = $content -replace 'vmx-20', "vmx-$TargetHwVersion"
    if ($content -eq $newContent) {
        Write-Warning "  no vmx-20 found in OVF — already vmx-$TargetHwVersion or different version?"
    }
    # UTF-8 no BOM (OVF spec) — preserve
    [System.IO.File]::WriteAllText($ovfFile.FullName, $newContent, [System.Text.UTF8Encoding]::new($false))

    # Remove .mf — its SHA hashes refer to the original .ovf; without removal
    # vCenter would fail SHA verify on import.
    $mfFiles = Get-ChildItem $tmp.FullName -Filter *.mf -File
    if ($mfFiles) {
        Write-Host "[3/4] removing $($mfFiles.Count) .mf (manifest signature mismatch otherwise)" -ForegroundColor Cyan
        $mfFiles | Remove-Item -Force
    } else { Write-Host "[3/4] no .mf to remove" -ForegroundColor Cyan }

    # Repack: ovf first, then disks sorted (tar order matters for streaming OVA)
    $allFiles = Get-ChildItem $tmp.FullName -File
    $ordered = @($ovfFile.Name) + ($allFiles | Where-Object { $_.Name -ne $ovfFile.Name } | Sort-Object Name | ForEach-Object { $_.Name })
    Write-Host "[4/4] repacking $($ordered.Count) files -> $Dest" -ForegroundColor Cyan
    Push-Location $tmp.FullName
    try {
        tar -cf $Dest $ordered
        if ($LASTEXITCODE -ne 0) { throw "tar create failed" }
    } finally { Pop-Location }

    $srcGB  = [math]::Round((Get-Item $Source).Length / 1GB, 2)
    $destGB = [math]::Round((Get-Item $Dest).Length / 1GB, 2)
    Write-Host "✓ done. src=$srcGB GB, dest=$destGB GB" -ForegroundColor Green
    return $Dest
} finally {
    Remove-Item -Recurse -Force $tmp.FullName -ErrorAction SilentlyContinue
}
