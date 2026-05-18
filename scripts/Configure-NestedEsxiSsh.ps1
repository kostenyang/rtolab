<#
.SYNOPSIS
    SSH 進剛裝好的 nested ESXi (master VM), 安裝 /etc/rc.local.d/local.sh first-boot
    configurator + 跑 auto-backup.sh 寫進 boot bank. 之後 clone 出來的 VM 開機會自動
    從 guestinfo 套 IP/hostname.

.PARAMETER EsxiHost
    ESXi 的 mgmt IP 或 FQDN, 例如 192.168.114.50.

.PARAMETER Password
    ESXi root pw (預設讀 inventory/secrets/lab.yaml.esxi.root_pw).

.EXAMPLE
    pwsh scripts\Configure-NestedEsxiSsh.ps1 -EsxiHost 192.168.114.50
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)] [string] $EsxiHost,
    [string] $Password
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $here '..')

if (-not (Get-Module -ListAvailable powershell-yaml)) {
    Install-Module powershell-yaml -Scope CurrentUser -Force | Out-Null
}
Import-Module powershell-yaml
if (-not (Get-Module -ListAvailable Posh-SSH)) {
    Install-Module Posh-SSH -Scope CurrentUser -Force | Out-Null
}
Import-Module Posh-SSH

if (-not $Password) {
    $secrets = Get-Content -Raw (Join-Path $repoRoot 'inventory/secrets/lab.yaml') | ConvertFrom-Yaml
    $Password = $secrets.esxi.root_pw
}

$localSh = @'
#!/bin/sh
# rtolab nested ESXi first-boot configurator
# 從 VMware Tools guestinfo (OVF vApp properties) 讀, 套 hostname/IP/network.
# 6 個 vSAN/LSOM 設定 + SSH 開 等 lab-level workaround 已由 Configure-NestedEsxiSsh
# 在 master export 前直接套到 ESXi state.tgz, clone 開機已繼承, local.sh 不再套.
# 第一次跑完落 /etc/rtolab-configured marker, 之後 reboot skip.

if [ -f /etc/rtolab-configured ]; then
    exit 0
fi

HOSTNAME=$(/usr/bin/vmware-rpctool 'info-get guestinfo.hostname' 2>/dev/null)
IPADDR=$(/usr/bin/vmware-rpctool   'info-get guestinfo.ipaddress' 2>/dev/null)
NETMASK=$(/usr/bin/vmware-rpctool  'info-get guestinfo.netmask' 2>/dev/null)
GATEWAY=$(/usr/bin/vmware-rpctool  'info-get guestinfo.gateway' 2>/dev/null)
VLAN=$(/usr/bin/vmware-rpctool     'info-get guestinfo.vlan' 2>/dev/null)
DNS=$(/usr/bin/vmware-rpctool      'info-get guestinfo.dns' 2>/dev/null)
DOMAIN=$(/usr/bin/vmware-rpctool   'info-get guestinfo.domain' 2>/dev/null)
NTP=$(/usr/bin/vmware-rpctool      'info-get guestinfo.ntp' 2>/dev/null)

# 沒 guestinfo (master 本機開機 / manual deploy), 就什麼都不動
[ -z "$HOSTNAME" ] && exit 0

# Hostname / FQDN
esxcli system hostname set --fqdn="$HOSTNAME" 2>/dev/null

# Mgmt vmk IPv4
if [ -n "$IPADDR" ] && [ -n "$NETMASK" ]; then
    esxcli network ip interface ipv4 set -i vmk0 -t static -I "$IPADDR" -N "$NETMASK" -g "$GATEWAY"
fi

# Default gateway
[ -n "$GATEWAY" ] && esxcli network ip route ipv4 add --gateway "$GATEWAY" --network default 2>/dev/null

# DNS
if [ -n "$DNS" ]; then
    esxcli network ip dns server remove --all 2>/dev/null
    esxcli network ip dns server add --server="$DNS"
fi
[ -n "$DOMAIN" ] && esxcli network ip dns search add --domain="$DOMAIN" 2>/dev/null

# VLAN on Management Network portgroup
[ -n "$VLAN" ] && esxcli network vswitch standard portgroup set -p "Management Network" --vlan-id="$VLAN" 2>/dev/null

# NTP
if [ -n "$NTP" ]; then
    /sbin/esxcli system ntp set -s "$NTP" -e true 2>/dev/null
    /etc/init.d/ntpd start 2>/dev/null
fi

touch /etc/rtolab-configured
'@

$securePw = ConvertTo-SecureString $Password -AsPlainText -Force
$cred = New-Object PSCredential 'root', $securePw

Write-Host "Connecting SSH root@$EsxiHost ..." -ForegroundColor Cyan
$session = New-SSHSession -ComputerName $EsxiHost -Credential $cred -AcceptKey -ConnectionTimeout 30 -ErrorAction Stop
try {
    Write-Host "  uploading local.sh..."
    # 寫到 /tmp 先 (POSH-SSH 預設位置), 再 mv
    $tmpFile = New-TemporaryFile
    Set-Content -Path $tmpFile -Value $localSh -Encoding UTF8 -NoNewline
    # Posh-SSH 沒 Copy-FileToSession 但有 New-SFTPSession
    $sftp = New-SFTPSession -ComputerName $EsxiHost -Credential $cred -AcceptKey -ConnectionTimeout 30
    Set-SFTPItem -SessionId $sftp.SessionId -Path $tmpFile.FullName -Destination '/etc/rc.local.d/' -Force
    # Rename
    Invoke-SSHCommand -SessionId $session.SessionId -Command "mv /etc/rc.local.d/$($tmpFile.Name) /etc/rc.local.d/local.sh && chmod +x /etc/rc.local.d/local.sh" | Out-Null
    Remove-Item $tmpFile -Force
    Remove-SFTPSession -SessionId $sftp.SessionId | Out-Null

    Write-Host "  /etc/rc.local.d/local.sh installed"

    Write-Host "  applying 6 vSAN/LSOM nested-lab workarounds (immediate, 不靠 local.sh)..."
    $advCmds = @(
        'esxcli system settings advanced set -o /LSOM/VSANDeviceMonitoring     -i 0',
        'esxcli system settings advanced set -o /LSOM/lsomSlowDeviceUnmount    -i 0',
        'esxcli system settings advanced set -o /VSAN/SwapThickProvisionDisabled -i 1',
        'esxcli system settings advanced set -o /VSAN/Vsan2ZdomCompZstd        -i 0',
        'esxcli system settings advanced set -o /VSAN/FakeSCSIReservations     -i 1',
        'esxcli system settings advanced set -o /VSAN/GuestUnmap               -i 1',
        # Suppress shell warnings
        'esxcli system settings advanced set -o /UserVars/SuppressShellWarning -i 1',
        'esxcli system settings advanced set -o /UserVars/SuppressHyperthreadWarning -i 1',
        # 開 SSH + Shell (這台 master 用; clone 從 OVA 繼承)
        'vim-cmd hostsvc/enable_ssh',  'vim-cmd hostsvc/start_ssh',
        'vim-cmd hostsvc/enable_esx_shell',  'vim-cmd hostsvc/start_esx_shell'
    )
    foreach ($cmd in $advCmds) { Invoke-SSHCommand -SessionId $session.SessionId -Command $cmd | Out-Null }
    Write-Host "    ✓ 6 vSAN settings + SSH/Shell + warning suppressions applied"

    Write-Host "  running /sbin/auto-backup.sh (寫進 boot bank, 重開機後仍在)..."
    $r = Invoke-SSHCommand -SessionId $session.SessionId -Command '/sbin/auto-backup.sh'
    Write-Host ("    " + (($r.Output -split "`n") | Select-Object -Last 2 | Out-String).Trim())

    Write-Host ""
    Write-Host "✓ ESXi @ $EsxiHost ready (manual install + local.sh + vSAN workarounds + auto-backup'd)" -ForegroundColor Green
} finally {
    Remove-SSHSession -SessionId $session.SessionId | Out-Null
}
