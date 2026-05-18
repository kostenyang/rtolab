<#
.SYNOPSIS
    給一台 nested ESXi VM 建一份 custom installer ISO (含 ks.cfg) — 走 UEFI boot,
    開機自動跑 kickstart 把 ESXi 裝到 disk 1, 套 IP/hostname/root pw, reboot.

.DESCRIPTION
    流程:
      1. Mount-DiskImage 原 ESXi ISO (E:\<v>\*.iso) -> 拷貝到 temp dir
      2. 抓 EFIBOOT.IMG (UEFI El Torito boot image)
      3. 改 EFI\BOOT\BOOT.CFG + BOOT.CFG (BIOS 那份備用), 加 'kernelopt=... ks=cdrom:/KS.CFG'
      4. 寫 KS.CFG (per-VM ks 含 IP/hostname/root pw 等)
      5. PwSh.Fw.Iso 的 New-IsoFileWindows -BootFile EFIBOOT.IMG -> 出 custom ISO
      6. Upload 到 vsanDatastore (1)/iso/ks-<vmname>.iso (用 PowerCLI Copy-DatastoreItem)
      7. (caller 自己 swap CDROM IsoPath + reboot VM)

    ks.cfg 內容 = vmaccepteula + clearpart --firstdisk --overwritevmfs +
                  install --firstdisk --overwritevmfs +
                  rootpw + network static + reboot.

.PARAMETER VMName
    例如 vcf-m02-esx01-521. 用來找 inventory 內這台的 fqdn / mgmt_ip / vlan.

.PARAMETER Version
    9.0 / 9.1 / 5.2.1. 用來找對應的 ESXi installer ISO 源.

.PARAMETER OutputIsoLocal
    輸出 ISO 路徑. 預設 E:\custom-iso\ks-<vmname>.iso

.PARAMETER UploadDatastorePath
    輸出 ISO 也 upload 到這個 datastore 路徑. 預設 '[vsanDatastore (1)] iso/ks-<vmname>.iso'

.PARAMETER NoUpload
    只 build local ISO, 不 upload.

.EXAMPLE
    pwsh scripts\Build-EsxiKickstartIso.ps1 -VMName vcf-m02-esx01-521 -Version 5.2.1
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)] [string] $VMName,
    [Parameter(Mandatory=$true)] [ValidateSet('9.0','9.1','5.2.1')] [string] $Version,
    [string] $OutputIsoLocal,
    [string] $UploadDatastorePath,
    [switch] $NoUpload
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $here '..')

if (-not (Get-Module -ListAvailable powershell-yaml)) {
    Install-Module powershell-yaml -Scope CurrentUser -Force | Out-Null
}
Import-Module powershell-yaml
if (-not (Get-Module -ListAvailable PwSh.Fw.Iso)) {
    Install-Module PwSh.Fw.Iso -Scope CurrentUser -Force | Out-Null
}
Import-Module PwSh.Fw.Iso

$inv     = Get-Content -Raw (Join-Path $repoRoot 'inventory/lab.yaml') | ConvertFrom-Yaml
$secrets = Get-Content -Raw (Join-Path $repoRoot 'inventory/secrets/lab.yaml') | ConvertFrom-Yaml

# 找 VM 的 host entry
$hostEntry = $inv.hosts_by_version[$Version] | Where-Object { $_.nested_vm_name -eq $VMName }
if (-not $hostEntry) { throw "VM '$VMName' 不在 inventory hosts_by_version[$Version]" }

$vKey = $Version -replace '\.',''
$sourceIso = $inv.artifacts."vcf_$vKey".esxi_iso_local
if (-not $sourceIso -or -not (Test-Path $sourceIso)) { throw "source ISO 找不到: $sourceIso" }

# Paths
if (-not $OutputIsoLocal) {
    $outDir = 'E:\custom-iso'
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
    $OutputIsoLocal = Join-Path $outDir "ks-$VMName.iso"
}
if (-not $UploadDatastorePath) {
    $UploadDatastorePath = "[vsanDatastore (1)] iso/ks-$VMName.iso"
}

# Per-host values from inventory
$mgmtIp   = $hostEntry.mgmt_ip
$fqdn     = $hostEntry.fqdn
$hostname = $fqdn.Split('.')[0]
$netmask  = '255.255.255.0'
$gateway  = $inv.network.mgmt.gateway
$vlan     = $inv.network.mgmt.vlan
$dns      = $inv.infra.ad_dns.ip
$rootPw   = $secrets.esxi.root_pw

Write-Host ""
Write-Host "Building kickstart ISO for $VMName ($Version):" -ForegroundColor Cyan
Write-Host "  source ISO  : $sourceIso"
Write-Host "  output local: $OutputIsoLocal"
Write-Host "  hostname    : $fqdn"
Write-Host "  ip/mask/gw  : $mgmtIp / $netmask / $gateway   vlan=$vlan"
Write-Host "  dns / rootpw: $dns / (from secrets)"

# ---- 1. Mount source ISO + extract to temp dir ---------------------------
$tmpDir = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "esxi-ks-$([Guid]::NewGuid().ToString('N'))") -Force
$mount = $null
try {
    Write-Host "[1/5] mount + copy source ISO..."
    $mount = Mount-DiskImage -ImagePath $sourceIso -PassThru
    Start-Sleep 2
    $drive = ($mount | Get-Volume).DriveLetter + ':\'
    robocopy $drive $tmpDir.FullName /MIR /NJH /NJS /NDL /NP /NC /NS /NFL 2>&1 | Out-Null
    Dismount-DiskImage -ImagePath $sourceIso | Out-Null
    $mount = $null
    # ISO 檔都是 read-only, robocopy 帶 R 屬性過來 -> 移除以便改 BOOT.CFG / 寫 KS.CFG
    Get-ChildItem -Path $tmpDir.FullName -Recurse -File | ForEach-Object { $_.IsReadOnly = $false }
} catch {
    if ($mount) { try { Dismount-DiskImage -ImagePath $sourceIso } catch {} }
    Remove-Item -Recurse -Force $tmpDir.FullName -ErrorAction SilentlyContinue
    throw
}

# ---- 2. Save EFIBOOT.IMG separately (PwSh.Fw.Iso needs file path as BootFile)
$efibootImg = Join-Path $tmpDir.FullName 'EFIBOOT.IMG'
if (-not (Test-Path $efibootImg)) { throw "EFIBOOT.IMG 不在 ISO 內: $efibootImg" }
$efibootCopy = Join-Path $env:TEMP "EFIBOOT-$([Guid]::NewGuid().ToString('N')).IMG"
Copy-Item $efibootImg $efibootCopy
Write-Host "[2/5] EFIBOOT.IMG: $efibootCopy ($((Get-Item $efibootCopy).Length) bytes)"

# ---- 3. Patch BOOT.CFG: 加 ks=cdrom:/KS.CFG -------------------------------
foreach ($bcPath in @(
    (Join-Path $tmpDir.FullName 'EFI\BOOT\BOOT.CFG'),
    (Join-Path $tmpDir.FullName 'BOOT.CFG')
)) {
    if (Test-Path $bcPath) {
        $content = [IO.File]::ReadAllText($bcPath)
        if ($content -match '^kernelopt=(.*)') {
            $newOpts = $matches[1].Trim()
            if ($newOpts -notmatch 'ks=cdrom') {
                $newOpts = ($newOpts + ' ks=cdrom:/KS.CFG').Trim()
            }
            $content = $content -replace 'kernelopt=.*', "kernelopt=$newOpts"
        } else {
            $content += "`nkernelopt=ks=cdrom:/KS.CFG`n"
        }
        [IO.File]::WriteAllText($bcPath, $content, [System.Text.UTF8Encoding]::new($false))
        Write-Host "[3/5] patched $bcPath"
    }
}

# ---- 4. Write KS.CFG ------------------------------------------------------
$ks = @"
# rtolab kickstart for $VMName ($Version)
vmaccepteula

# Root password
rootpw $rootPw

# Wipe disk 1 (10GB SCSI boot disk) + install
clearpart --firstdisk --overwritevmfs
install --firstdisk --overwritevmfs --novmfsondisk

# Network (static IP, VLAN-tagged inside ESXi)
network --bootproto=static --device=vmnic0 --ip=$mgmtIp --netmask=$netmask --gateway=$gateway --hostname=$hostname --nameserver=$dns --vlanid=$vlan

# Reboot after install
reboot --noeject

%firstboot --interpreter=busybox

# Enable + start SSH/ESXi shell
vim-cmd hostsvc/enable_ssh
vim-cmd hostsvc/start_ssh
vim-cmd hostsvc/enable_esx_shell
vim-cmd hostsvc/start_esx_shell

# Disable suppress shell warnings
esxcli system settings advanced set -o /UserVars/SuppressShellWarning -i 1
esxcli system settings advanced set -o /UserVars/SuppressHyperthreadWarning -i 1
"@
[IO.File]::WriteAllText((Join-Path $tmpDir.FullName 'KS.CFG'), $ks, [System.Text.UTF8Encoding]::new($false))
Write-Host "[4/5] wrote KS.CFG ($($ks.Length) chars)"

# ---- 5. Build ISO ---------------------------------------------------------
if (Test-Path $OutputIsoLocal) { Remove-Item -Force $OutputIsoLocal }
Write-Host "[5/5] building ISO..."
$null = New-IsoFileWindows -Source $tmpDir.FullName -Path $OutputIsoLocal `
                           -BootFile $efibootCopy -Media DVDPLUSR -Title 'ESXI' -Force

Remove-Item $efibootCopy -Force
Remove-Item -Recurse -Force $tmpDir.FullName

Write-Host "✓ ISO built: $OutputIsoLocal ($([math]::Round((Get-Item $OutputIsoLocal).Length/1MB,0)) MB)" -ForegroundColor Green

# ---- 6. Upload to datastore -----------------------------------------------
if (-not $NoUpload) {
    Write-Host "Uploading to '$UploadDatastorePath'..." -ForegroundColor Cyan
    Import-Module VMware.VimAutomation.Core
    Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null
    Connect-VIServer $inv.infra.outer_vcenter.fqdn -User $inv.infra.outer_vcenter.user -Password $secrets.outer_vcenter.sso_admin_pw | Out-Null
    $ds = Get-Datastore 'vsanDatastore (1)'
    New-PSDrive -Name VCDS -PSProvider VimDatastore -Root '\' -Datastore $ds | Out-Null
    $relPath = $UploadDatastorePath -replace '^\[vsanDatastore \(1\)\] ', 'VCDS:\' -replace '/','\'
    Copy-DatastoreItem -Item $OutputIsoLocal -Destination $relPath -Force
    Remove-PSDrive VCDS
    Disconnect-VIServer * -Confirm:$false -Force | Out-Null
    Write-Host "✓ uploaded to $UploadDatastorePath" -ForegroundColor Green
}

Write-Host ""
Write-Host "下一步: swap VM CDROM IsoPath -> '$UploadDatastorePath' 然後重啟 VM" -ForegroundColor Cyan
Write-Host "  Get-VM $VMName | Get-CDDrive | Set-CDDrive -IsoPath '$UploadDatastorePath' -StartConnected:`$true -Confirm:`$false"
Write-Host "  Restart-VM $VMName -Confirm:`$false"
