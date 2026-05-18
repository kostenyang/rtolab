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
# 從 VMware Tools guestinfo (OVF vApp properties) 讀, 套到 ESXi.
# 第一次跑完落 marker file, 之後 reboot 就 skip.

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
PASSWORD=$(/usr/bin/vmware-rpctool 'info-get guestinfo.password' 2>/dev/null)
NTP=$(/usr/bin/vmware-rpctool      'info-get guestinfo.ntp' 2>/dev/null)

# 沒 guestinfo (例如 manual deploy 直接開機), 就什麼都不動
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

# Root password (option, 注意 ESXi 8 加密 hash 要先做)
# (略, 保留現 install 時設的 password)

# NTP
if [ -n "$NTP" ]; then
    /sbin/esxcli system ntp set -s "$NTP" -e true 2>/dev/null
    /etc/init.d/ntpd start 2>/dev/null
fi

# 開 SSH (給 PowerCLI 後續維運用)
vim-cmd hostsvc/enable_ssh 2>/dev/null
vim-cmd hostsvc/start_ssh 2>/dev/null
vim-cmd hostsvc/enable_esx_shell 2>/dev/null
vim-cmd hostsvc/start_esx_shell 2>/dev/null

# Suppress shell warnings (lab use)
esxcli system settings advanced set -o /UserVars/SuppressShellWarning -i 1 2>/dev/null
esxcli system settings advanced set -o /UserVars/SuppressHyperthreadWarning -i 1 2>/dev/null

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
    Write-Host "  running /sbin/auto-backup.sh (寫進 boot bank, 重開機後仍在)..."
    $r = Invoke-SSHCommand -SessionId $session.SessionId -Command '/sbin/auto-backup.sh'
    Write-Host $r.Output

    Write-Host "  enable SSH for future automation..."
    Invoke-SSHCommand -SessionId $session.SessionId -Command 'vim-cmd hostsvc/enable_ssh; vim-cmd hostsvc/start_ssh' | Out-Null

    Write-Host ""
    Write-Host "✓ ESXi @ $EsxiHost ready to be ConvertTo-Template'd (剛 manual install + local.sh + auto-backup'd)" -ForegroundColor Green
} finally {
    Remove-SSHSession -SessionId $session.SessionId | Out-Null
}
