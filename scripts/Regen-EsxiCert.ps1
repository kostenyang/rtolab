<#
.SYNOPSIS
    SSH 進 ESXi, 跑 /sbin/generate-certificates 重新發 SSL cert (CN = current FQDN),
    重啟 hostd/rhttpproxy 讓新 cert 生效, 然後 /sbin/auto-backup.sh persist.

    解 "ESXI_HOST_CERTIFICATE_CN_NOT_VALID" — master 在 hostname 還是 localhost 時
    自簽的 cert 落到 clone 上去, CN 跟 FQDN 不符.
#>
[CmdletBinding()]
param([Parameter(Mandatory=$true)] [string[]] $EsxiHosts)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $here '..')
Import-Module Posh-SSH
Import-Module powershell-yaml
$secrets = Get-Content -Raw (Join-Path $repoRoot 'inventory/secrets/lab.yaml') | ConvertFrom-Yaml
$pw = ConvertTo-SecureString $secrets.esxi.root_pw -AsPlainText -Force
$cred = New-Object PSCredential 'root', $pw

foreach ($ip in $EsxiHosts) {
    Write-Host ""
    Write-Host "=== $ip regen cert ===" -ForegroundColor Cyan
    $s = New-SSHSession -ComputerName $ip -Credential $cred -AcceptKey -ConnectionTimeout 15 -ErrorAction SilentlyContinue
    if (-not $s) { Write-Warning "  SSH failed, skip"; continue }
    try {
        $cmds = @(
            'esxcli system hostname get | grep -E "Host|Fully"',
            '/sbin/generate-certificates',
            '/etc/init.d/hostd restart',
            '/etc/init.d/rhttpproxy restart',
            'sleep 3',
            'openssl x509 -in /etc/vmware/ssl/rui.crt -noout -subject',
            '/sbin/auto-backup.sh'
        )
        foreach ($c in $cmds) {
            Write-Host "  > $c"
            $r = Invoke-SSHCommand -SessionId $s.SessionId -Command $c -TimeOut 60
            if ($r.Output) { $r.Output | Select-Object -First 5 | ForEach-Object { Write-Host "    $_" } }
        }
        Write-Host "  ✓ $ip cert regenerated" -ForegroundColor Green
    } finally {
        Remove-SSHSession -SessionId $s.SessionId | Out-Null
    }
}
